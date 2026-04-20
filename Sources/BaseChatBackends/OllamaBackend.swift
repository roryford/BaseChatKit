import Foundation
import os
import BaseChatInference

/// Inference backend for Ollama servers using the native `/api/chat` endpoint.
///
/// Ollama streams responses as newline-delimited JSON (NDJSON) rather than SSE,
/// so this backend overrides ``parseResponseStream(bytes:continuation:)`` to parse
/// each line directly instead of using `SSEStreamParser`.
///
/// Use ``OllamaModelListService`` to discover available models before configuring
/// this backend.
///
/// Usage:
/// ```swift
/// let backend = OllamaBackend()
/// backend.configure(baseURL: URL(string: "http://localhost:11434")!, modelName: "llama3.2")
/// try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await event in stream.events { if case .token(let t) = event { print(t, terminator: "") } }
/// ```
public final class OllamaBackend: SSECloudBackend, CloudBackendURLModelConfigurable, @unchecked Sendable {

    /// How long Ollama should keep the model loaded in VRAM after a request.
    /// Default is "30m" (30 minutes). Ollama's own default is "5m".
    public var keepAlive: String = "30m"

    // MARK: - Init

    /// Creates an Ollama backend.
    ///
    /// - Parameter urlSession: Custom URLSession for testing. Pass `nil` to use the default.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "llama3.2",
            urlSession: urlSession ?? URLSessionProvider.unpinned,
            payloadHandler: OllamaPayloadHandler()
        )
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "Ollama" }

    public override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP, .topK, .repeatPenalty],
            maxContextTokens: 128_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 128_000,
            supportsStreaming: true,
            isRemote: true
        )
    }

    // MARK: - Model Lifecycle

    // Plan is informational for cloud backends.
    public override func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:modelName:) first."
            )
        }
        setIsModelLoaded(true)
        Log.inference.info("OllamaBackend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public)")
    }

    // MARK: - Request Building

    public override func buildRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> URLRequest {
        guard let baseURL else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }

        let chatURL = baseURL.appendingPathComponent("api/chat")

        var messages: [[String: String]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        if let history = conversationHistory {
            messages.append(contentsOf: history.map { ["role": $0.role, "content": $0.content] })
        } else {
            messages.append(["role": "user", "content": prompt])
        }

        // For thinking models (e.g. gemma4, qwen3), Ollama counts thinking tokens
        // against num_predict. Reserve budget for both thinking and visible output
        // so the model isn't silently cut off mid-think before any content is produced.
        // maxOutputTokens is enforced client-side in parseResponseStream using the
        // server's own `eval_count` when it appears on a line (running count on
        // intermediate lines where servers emit it, or the final done-line count);
        // a per-line counter remains as a fallback for servers that don't.
        let visibleBudget = config.maxOutputTokens ?? 2048
        let thinkingBudget = config.maxThinkingTokens ?? 2048
        let options: [String: Any] = [
            "temperature": config.temperature,
            "top_p": config.topP,
            "top_k": config.topK.map { Int($0) } ?? 40,
            "repeat_penalty": config.repeatPenalty,
            "num_predict": visibleBudget + thinkingBudget,
        ]

        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "options": options,
            "keep_alive": keepAlive,
        ]

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.network.debug("OllamaBackend request to \(chatURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - NDJSON Stream Parsing

    // TODO: (#189) Detect Ollama model-loading state and set GenerationStream
    // phase to .loading. Requires the monitoring task pattern from
    // GenerationStream to detect the pre-first-token stall that indicates
    // Ollama is loading the model into VRAM. The stall detection at
    // timeout/2 partially addresses this by showing .stalled.

    /// Parses Ollama's NDJSON response format instead of SSE.
    ///
    /// Applies the same ``SSEStreamLimits`` caps as the SSE parser so a
    /// hostile Ollama-compatible server cannot exhaust memory with oversized
    /// lines, total volume, or an event flood.
    ///
    /// Reasoning models (qwen3, qwen3.5:4b, deepseek-r1) surface chain-of-thought
    /// tokens in a separate `thinking` field — `message.thinking` on the
    /// `/api/chat` endpoint and top-level `thinking` on `/api/generate`. We
    /// emit ``GenerationEvent/thinkingToken(_:)`` while a line carries
    /// non-empty thinking, and ``GenerationEvent/thinkingComplete`` exactly
    /// once — either on the transition from "thinking was non-empty" to
    /// "thinking is now empty", or on `"done":true` when a thinking
    /// accumulator is still open. ``GenerationConfig/maxThinkingTokens``
    /// caps reasoning emission; once exceeded subsequent thinking content is
    /// dropped and only visible ``GenerationEvent/token(_:)`` events continue.
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let limits = effectiveSSEStreamLimits
        var lineBuffer = Data()
        var totalBytes = 0
        var rateWindowStart = ContinuousClock.now
        var rateWindowCount = 0

        // Tracks whether we've emitted any thinking content on this stream,
        // so we know when to fire the single .thinkingComplete event.
        var thinkingOpen = false
        var thinkingTokenCount = 0
        let thinkingLimit = config.maxThinkingTokens
        // Fallback per-line counter for servers that don't emit `eval_count`
        // until the done-line. When a line carries `eval_count`, we prefer it
        // over this counter for an exact cap.
        var visibleLineCount = 0
        let visibleLimit = config.maxOutputTokens

        func noteEventYielded() throws {
            let now = ContinuousClock.now
            if now - rateWindowStart >= .seconds(1) {
                rateWindowStart = now
                rateWindowCount = 1
                return
            }
            rateWindowCount += 1
            if rateWindowCount > limits.maxEventsPerSecond {
                throw SSEStreamError.eventRateExceeded(rateWindowCount)
            }
        }

        func handleLine(_ line: String) throws {
            guard let parsed = Self.parseLine(line) else { return }

            // Route thinking field (if any) first so downstream consumers see
            // reasoning before visible content for a given NDJSON record.
            if let thinking = parsed.thinking, !thinking.isEmpty {
                if let limit = thinkingLimit, thinkingTokenCount >= limit {
                    // Cap reached — drop this thinking chunk silently.
                } else {
                    try noteEventYielded()
                    continuation.yield(.thinkingToken(thinking))
                    thinkingOpen = true
                    // Count each thinking-bearing NDJSON line as one "token"
                    // for cap purposes. Ollama ships whole-blob thinking per
                    // line rather than per-token, so this matches the
                    // coarser grain of the wire format.
                    thinkingTokenCount += 1
                }
            } else if thinkingOpen {
                // Transition from thinking → content. Fire .thinkingComplete
                // exactly once on the first empty-thinking line we see after
                // any non-empty thinking was emitted.
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
            }

            if let content = parsed.content, !content.isEmpty {
                // Prefer the server's running `eval_count` when present for an
                // exact token-count cap; otherwise fall back to the NDJSON line
                // counter which is an upper bound but may overshoot by one line.
                if let limit = visibleLimit {
                    let observed = parsed.evalCount ?? visibleLineCount
                    if observed >= limit {
                        // Client-side cap reached; stop the stream cleanly.
                        continuation.finish()
                        return
                    }
                }
                try noteEventYielded()
                continuation.yield(.token(content))
                visibleLineCount += 1
            }

            if parsed.done {
                // Ollama can terminate with `"done":true` while thinking is
                // still the only content emitted (e.g. reasoning model hits
                // num_predict mid-think). Flush .thinkingComplete so
                // downstream consumers don't leave the thinking block open.
                if thinkingOpen {
                    try noteEventYielded()
                    continuation.yield(.thinkingComplete)
                    thinkingOpen = false
                }

                // Surface usage from the done-line (`eval_count`,
                // `prompt_eval_count`). This wires into `handleUsage` (which
                // populates `lastUsage` for `TokenUsageProvider` consumers) and
                // emits a `.usage` event on the stream, mirroring the SSE path
                // in `SSECloudBackend.parseResponseStream`.
                if parsed.evalCount != nil || parsed.promptEvalCount != nil {
                    let usage: (promptTokens: Int?, completionTokens: Int?) = (
                        promptTokens: parsed.promptEvalCount,
                        completionTokens: parsed.evalCount
                    )
                    handleUsage(usage)
                    if let prompt = usage.promptTokens,
                       let completion = usage.completionTokens {
                        try noteEventYielded()
                        continuation.yield(.usage(prompt: prompt, completion: completion))
                    }
                }
            }
        }

        for try await byte in bytes {
            if Task.isCancelled { break }

            totalBytes += 1
            if totalBytes > limits.maxTotalBytes {
                throw SSEStreamError.streamTooLarge(totalBytes)
            }

            if byte == UInt8(ascii: "\n") {
                if !lineBuffer.isEmpty {
                    if let line = String(data: lineBuffer, encoding: .utf8) {
                        try handleLine(line)
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            } else {
                lineBuffer.append(byte)
                if lineBuffer.count > limits.maxEventBytes {
                    throw SSEStreamError.eventTooLarge(lineBuffer.count)
                }
            }
        }

        // Flush any final line without a trailing newline.
        if !lineBuffer.isEmpty,
           let line = String(data: lineBuffer, encoding: .utf8) {
            try handleLine(line)
        }

        // Safety net: if the stream ends while thinking is still "open"
        // (no done-chunk, no empty-thinking transition), still close it out
        // so consumers don't hang in a thinking-only state.
        if thinkingOpen {
            try noteEventYielded()
            continuation.yield(.thinkingComplete)
        }
    }

    // MARK: - HTTP Status Validation

    public override func checkStatusCode(
        _ response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        let statusCode = response.statusCode
        guard !(200...299).contains(statusCode) else { return }

        switch statusCode {
        case 404:
            throw CloudBackendError.serverError(statusCode: 404, message: "Model not found. Pull the model with `ollama pull <model>` first.")
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CloudBackendError.rateLimited(retryAfter: retryAfter)
        default:
            var errorBodyData = Data()
            for try await byte in bytes {
                errorBodyData.append(byte)
                if errorBodyData.count > 2048 { break }
            }
            let errorBody = String(decoding: errorBodyData, as: UTF8.self)
            Log.network.debug("Ollama upstream error body: \(errorBody, privacy: .private)")
            let host = self.baseURL?.host()
            let message = CloudErrorSanitizer.sanitize(
                Self.extractErrorMessage(from: errorBody),
                host: host
            )
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
    }

    // MARK: - NDJSON Parsing

    /// Decoded shape of a single Ollama NDJSON record.
    ///
    /// Ollama's two endpoints carry data in different places:
    /// - `/api/chat` streams put content in `message.content` and reasoning in
    ///   `message.thinking`.
    /// - `/api/generate` (non-chat) uses top-level `response` and top-level
    ///   `thinking`.
    /// `parseLine` normalises both shapes; consumers read `content` and
    /// `thinking` without caring which endpoint produced the line.
    ///
    /// `evalCount` / `promptEvalCount` are the exact token counts reported by
    /// the Ollama server. Per Ollama's documented API, these appear on the
    /// terminal `"done":true` line — `eval_count` is the number of tokens the
    /// model produced this turn and `prompt_eval_count` is the number of tokens
    /// in the prompt. Some Ollama-compatible servers also emit a running
    /// `eval_count` on intermediate lines; parsing it unconditionally lets the
    /// stream cap visible output precisely when available and falls back to a
    /// line counter when not.
    struct ParsedLine {
        var content: String?
        var thinking: String?
        var done: Bool
        var evalCount: Int?
        var promptEvalCount: Int?
    }

    /// Parses a single Ollama NDJSON line into a normalised shape.
    ///
    /// Returns `nil` for malformed lines so the stream parser can skip them
    /// the same way it historically skipped unparseable JSON.
    static func parseLine(_ json: String) -> ParsedLine? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let done = (parsed["done"] as? Bool) ?? false

        var content: String?
        var thinking: String?

        if let message = parsed["message"] as? [String: Any] {
            // `/api/chat` shape.
            content = message["content"] as? String
            thinking = message["thinking"] as? String
        }

        // `/api/generate` shape — top-level `response` and `thinking`. If both
        // `message.content` and top-level `response` are present (shouldn't
        // happen in practice), chat-shape wins because it arrived first.
        if content == nil, let response = parsed["response"] as? String {
            content = response
        }
        if thinking == nil, let topThinking = parsed["thinking"] as? String {
            thinking = topThinking
        }

        // Usage fields — `eval_count` (output tokens) and `prompt_eval_count`
        // (prompt tokens). Documented as done-line fields but we parse them
        // unconditionally so a running-count-emitting server is handled too.
        let evalCount = parsed["eval_count"] as? Int
        let promptEvalCount = parsed["prompt_eval_count"] as? Int

        return ParsedLine(
            content: content,
            thinking: thinking,
            done: done,
            evalCount: evalCount,
            promptEvalCount: promptEvalCount
        )
    }

    /// Extracts the assistant content token from an Ollama NDJSON line.
    ///
    /// Ollama streaming format (one JSON object per line, no `data:` prefix):
    /// ```json
    /// {"model":"llama3","message":{"role":"assistant","content":"Hello"},"done":false}
    /// ```
    /// Final chunk has `"done":true` and empty or absent content — we skip it.
    ///
    /// This method only surfaces visible content; reasoning-model `thinking`
    /// fields are handled inline by ``parseResponseStream(bytes:config:continuation:)``
    /// so they can be emitted as ``GenerationEvent/thinkingToken(_:)`` with
    /// proper ``GenerationEvent/thinkingComplete`` bracketing. Kept for the
    /// ``SSEPayloadHandler`` protocol conformance and external callers.
    static func extractToken(from json: String) -> String? {
        guard let parsed = parseLine(json) else { return nil }
        // Skip the final "done" chunk.
        if parsed.done { return nil }
        guard let content = parsed.content, !content.isEmpty else { return nil }
        return content
    }

    /// Extracts reasoning content from an Ollama NDJSON line, if any.
    ///
    /// Returns `nil` when the line carries no `thinking` field or an empty
    /// one. Exposed for symmetry with ``extractToken(from:)``; streaming
    /// callers use the inline logic in
    /// ``parseResponseStream(bytes:config:continuation:)`` to bracket
    /// thinking emissions with ``GenerationEvent/thinkingComplete``.
    static func extractThinking(from json: String) -> String? {
        guard let parsed = parseLine(json),
              let thinking = parsed.thinking,
              !thinking.isEmpty else {
            return nil
        }
        return thinking
    }

    /// Extracts an error message from an Ollama error response body.
    ///
    /// Ollama error format: `{"error":"model not found"}`
    private static func extractErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = parsed["error"] as? String else {
            return nil
        }
        return message
    }

    // MARK: - SSE Payload Handler

    /// Ollama-specific ``SSEPayloadHandler`` for use with ``SSEStreamParser``.
    ///
    /// ``OllamaBackend`` overrides ``parseResponseStream(bytes:continuation:)``
    /// to handle NDJSON directly, so these methods are not called during normal
    /// operation. They are provided for completeness and external reuse.
    struct OllamaPayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            OllamaBackend.extractToken(from: payload)
        }

        /// Extracts Ollama's per-turn usage from a single NDJSON payload.
        ///
        /// Ollama's documented API places `eval_count` (completion tokens) and
        /// `prompt_eval_count` (prompt tokens) on the terminal `"done":true`
        /// line. Returns `nil` when neither field is present so partial/running
        /// lines don't pollute a consumer that expects "final usage only".
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            guard let parsed = OllamaBackend.parseLine(payload) else { return nil }
            guard parsed.evalCount != nil || parsed.promptEvalCount != nil else {
                return nil
            }
            return (
                promptTokens: parsed.promptEvalCount,
                completionTokens: parsed.evalCount
            )
        }

        func isStreamEnd(_ payload: String) -> Bool { false }
        func extractStreamError(from payload: String) -> Error? { nil }
    }

    // MARK: - Unload

    public override func unloadModel() {
        super.unloadModel()
    }
}

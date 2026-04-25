#if CloudSaaS
import Foundation
import os
import BaseChatInference

/// Cloud inference backend targeting OpenAI's Responses API
/// (`POST /v1/responses`).
///
/// Unlike ``OpenAIBackend`` (Chat Completions), the Responses API is a
/// named-event SSE stream that exposes reasoning summaries as first-class
/// events:
///
/// ```
/// event: response.output_item.added
/// data: {"type":"response.output_item.added","item":{"type":"reasoning"}}
///
/// event: response.reasoning_summary_text.delta
/// data: {"delta":"Let me think..."}
///
/// event: response.reasoning_summary_text.done
/// data: {}
///
/// event: response.output_text.delta
/// data: {"delta":"The answer is 42."}
///
/// event: response.completed
/// data: {"response":{"usage":{"input_tokens":12,"output_tokens":8}}}
/// ```
///
/// Reasoning summaries surface as ``GenerationEvent/thinkingToken(_:)``
/// values, with a single ``GenerationEvent/thinkingComplete`` injected on
/// the transition to visible output. This routing mirrors the convention
/// used by ``ClaudeBackend`` and ``OpenAIBackend`` so consumers can stay
/// agnostic of the wire format.
///
/// Usage:
/// ```swift
/// let backend = OpenAIResponsesBackend()
/// backend.configure(
///     baseURL: URL(string: "https://api.openai.com")!,
///     apiKey: "sk-...",
///     modelName: "gpt-5"
/// )
/// try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await event in stream.events {
///     switch event {
///     case .thinkingToken(let t): print("[reasoning]", t)
///     case .token(let t): print(t, terminator: "")
///     default: break
///     }
/// }
/// ```
public final class OpenAIResponsesBackend: SSECloudBackend, TokenUsageProvider, CloudBackendURLModelConfigurable, CloudBackendKeychainConfigurable, @unchecked Sendable {

    // MARK: - Init

    /// Creates an OpenAI Responses-API backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the
    ///   default pinned session.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "gpt-5",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            // Payload handler is unused — this backend overrides
            // `parseResponseStream` to walk the named-event stream directly.
            // A no-op handler keeps the base class's compile-time contract.
            payloadHandler: NoopPayloadHandler()
        )
    }

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    public static func makeChecked(urlSession: URLSession? = nil) throws -> OpenAIResponsesBackend {
        let session: URLSession
        if let urlSession {
            session = urlSession
        } else {
            session = try URLSessionProvider.throwingPinned()
        }
        return OpenAIResponsesBackend(urlSession: session)
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "OpenAIResponses" }

    public override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 200_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 16_384,
            supportsStreaming: true,
            isRemote: true,
            supportsThinking: true
        )
    }

    // MARK: - Model Lifecycle

    public override func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:apiKey:modelName:) first."
            )
        }
        setIsModelLoaded(true)
        Log.inference.info("OpenAI Responses backend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public)")
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

        let responsesURL = baseURL.appendingPathComponent("v1/responses")

        var input: [[String: String]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            input.append(["role": "system", "content": systemPrompt])
        }
        if let history = conversationHistory {
            // The Responses API accepts the same `(role, content)` shape as
            // Chat Completions for plain text turns; reasoning items are
            // server-managed and not replayed by the client.
            input.append(contentsOf: history.map { ["role": $0.role, "content": $0.content] })
        } else {
            input.append(["role": "user", "content": prompt])
        }

        var body: [String: Any] = [
            "model": modelName,
            "input": input,
            "stream": true,
            "temperature": config.temperature,
            "top_p": config.topP,
            "max_output_tokens": config.maxOutputTokens ?? 2048
        ]

        // Only request a reasoning summary when the caller asks for thinking
        // output. Sending `reasoning` to non-reasoning models is rejected by
        // the API, so we omit it unless the caller signals intent.
        if config.maxThinkingTokens != nil {
            body["reasoning"] = ["effort": "medium"]
        }

        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = resolveAPIKey(), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.network.debug("OpenAI Responses request to \(responsesURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - Stream Parsing

    /// Parses the Responses-API named-event SSE stream.
    ///
    /// The stock ``SSEStreamParser`` discards `event:` lines, but the
    /// Responses API distinguishes events purely by name (the data payload
    /// is just `{"delta":"..."}` with no `type` field). We therefore walk
    /// the byte stream ourselves, pairing each `event:` line with its
    /// following `data:` line.
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

        var currentEventName: String?

        // Tracks whether any reasoning_summary delta has been emitted on
        // this stream. We flush a single `.thinkingComplete` on the
        // transition to visible content so consumers see a clean handoff.
        var thinkingOpen = false

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

        func flushThinkingCompleteIfNeeded() throws {
            if thinkingOpen {
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
            }
        }

        // Returns `true` if the caller should break out of the byte loop
        // (terminal event observed).
        func handleEvent(name: String, data: String) throws -> Bool {
            // Match either `reasoning_summary_text` or `reasoning_summary`
            // — providers vary on the exact suffix.
            let isReasoningDelta = name == "response.reasoning_summary_text.delta"
                || name == "response.reasoning_summary.delta"
            let isReasoningDone = name == "response.reasoning_summary_text.done"
                || name == "response.reasoning_summary.done"

            if isReasoningDelta {
                if let delta = Self.parseDelta(from: data), !delta.isEmpty {
                    try noteEventYielded()
                    continuation.yield(.thinkingToken(delta))
                    thinkingOpen = true
                }
                return false
            }

            if isReasoningDone {
                try flushThinkingCompleteIfNeeded()
                return false
            }

            if name == "response.output_text.delta" {
                if let delta = Self.parseDelta(from: data), !delta.isEmpty {
                    try flushThinkingCompleteIfNeeded()
                    try noteEventYielded()
                    continuation.yield(.token(delta))
                }
                return false
            }

            if name == "response.completed" {
                try flushThinkingCompleteIfNeeded()
                if let usage = Self.parseUsage(from: data) {
                    handleUsage(usage)
                    if let prompt = usage.promptTokens,
                       let completion = usage.completionTokens {
                        continuation.yield(.usage(prompt: prompt, completion: completion))
                    }
                }
                return true
            }

            if name == "response.error" {
                let message = Self.parseErrorMessage(from: data) ?? "unknown error"
                throw CloudBackendError.serverError(statusCode: 500, message: message)
            }

            // Unknown event names (e.g. `response.output_item.added`,
            // `response.content_part.added`) are accepted silently — they
            // carry structural metadata we don't need today.
            return false
        }

        var iterator = bytes.makeAsyncIterator()
        outer: while let byte = try await iterator.next() {
            if Task.isCancelled { break }

            totalBytes += 1
            if totalBytes > limits.maxTotalBytes {
                throw SSEStreamError.streamTooLarge(totalBytes)
            }

            if byte != UInt8(ascii: "\n") {
                lineBuffer.append(byte)
                if lineBuffer.count > limits.maxEventBytes {
                    throw SSEStreamError.eventTooLarge(lineBuffer.count)
                }
                continue
            }

            let line: String
            if let decoded = String(data: lineBuffer, encoding: .utf8) {
                line = decoded.trimmingCharacters(in: .whitespaces)
            } else {
                Log.network.warning("OpenAIResponsesBackend: skipped \(lineBuffer.count)-byte line with invalid UTF-8")
                lineBuffer.removeAll(keepingCapacity: true)
                continue
            }
            lineBuffer.removeAll(keepingCapacity: true)

            if line.isEmpty {
                // Blank line marks event boundary; pending event is
                // already paired with its data line by this point.
                currentEventName = nil
                continue
            }

            if line.hasPrefix("event:") {
                currentEventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("data:") {
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard let name = currentEventName else {
                    // `data:` without a preceding `event:` — ignore. The
                    // Responses API always names its events.
                    continue
                }
                if try handleEvent(name: name, data: payload) {
                    break outer
                }
            }
            // `id:`, `retry:`, comment lines (`:`) are ignored.
        }

        try flushThinkingCompleteIfNeeded()
    }

    // MARK: - JSON Parsing

    /// Extracts a `delta` string from a Responses-API event payload.
    static func parseDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed["delta"] as? String
    }

    /// Extracts a usage tuple from a `response.completed` payload.
    ///
    /// Shape:
    /// ```json
    /// {"response":{"usage":{"input_tokens":12,"output_tokens":8}}}
    /// ```
    static func parseUsage(from json: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The usage block can sit at the top level (`{"usage":{...}}`) or
        // nested under `response` — accept either.
        let usage: [String: Any]?
        if let top = parsed["usage"] as? [String: Any] {
            usage = top
        } else if let response = parsed["response"] as? [String: Any],
                  let nested = response["usage"] as? [String: Any] {
            usage = nested
        } else {
            usage = nil
        }
        guard let usage else { return nil }
        let prompt = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int
        let completion = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int
        if prompt == nil && completion == nil { return nil }
        return (prompt, completion)
    }

    /// Extracts an error message from a `response.error` payload.
    static func parseErrorMessage(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = parsed["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return parsed["message"] as? String
    }

    // MARK: - No-op payload handler

    /// Placeholder handler — the base ``SSECloudBackend`` requires one at
    /// init, but this backend overrides ``parseResponseStream`` so the
    /// handler is never consulted.
    private struct NoopPayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? { nil }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
        func isStreamEnd(_ payload: String) -> Bool { false }
        func extractStreamError(from payload: String) -> Error? { nil }
    }
}
#endif

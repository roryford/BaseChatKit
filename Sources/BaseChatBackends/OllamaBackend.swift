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

    /// Whether the currently-loaded Ollama model advertises thinking/reasoning
    /// capability. Detected once at `loadModel` time by probing `/api/show`
    /// for `capabilities: ["thinking"]` or Jinja template markers
    /// (`<think>`, `{{ if .Thinking }}`, etc.). Defaults to `false` when the
    /// probe fails or the server returns an unexpected shape — detection is a
    /// best-effort optimisation, never a blocker.
    ///
    /// Consumers: `buildRequest` uses this flag to decide whether
    /// `maxThinkingTokens == nil` should reserve a 2048-token thinking budget
    /// (thinking models only) and whether `maxThinkingTokens == 0` should
    /// forward `"think": false` on the wire (thinking models only; Ollama
    /// silently ignores the flag on non-thinking models but we omit it for
    /// clean request bodies).
    public private(set) var isThinkingModel: Bool = false

    /// Conservative floor for `num_ctx` when the caller did not plumb a real
    /// context budget via `ModelLoadPlan` (`.cloud()` default is `1`).
    /// Ollama's server-side `OLLAMA_CONTEXT_LENGTH` defaults to 2048 tokens,
    /// which silently truncates multi-turn conversations with no error signal.
    /// 8192 matches what most mainstream local models are happy with and keeps
    /// multi-turn chat working even when the caller forgot to size the plan.
    static let defaultNumCtxFloor: Int = 8192

    /// Effective context size derived from the `ModelLoadPlan` passed to
    /// `loadModel(from:plan:)`. Used to populate Ollama's `options.num_ctx` in
    /// every request body so the server doesn't fall back to its 2048-token
    /// default (the silent-truncation footgun). Falls back to
    /// ``defaultNumCtxFloor`` when the plan carries a non-meaningful size
    /// (the `.cloud()` factory defaults to `1`).
    private var effectiveNumCtx: Int = defaultNumCtxFloor

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
            supportsNativeJSONMode: true,
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
        guard let configuredBaseURL = baseURL else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:modelName:) first."
            )
        }

        // Validate the configured host against DNS rebinding / SSRF before
        // any network I/O fires — must run before /api/show probe below.
        try await DNSRebindingGuard.validate(url: configuredBaseURL)

        // Ollama v0.18.0+ routes any model tag ending in `:cloud` to remote
        // inference (Ollama's hosted service) rather than the local server.
        // BaseChatKit positions itself as local-first, so silently sending
        // prompts off-device would violate the caller's expectation — throw a
        // descriptive error at load time rather than leak conversation content
        // to a remote endpoint the user didn't consciously opt into.
        if modelName.hasSuffix(":cloud") {
            throw CloudBackendError.invalidURL(
                "Ollama model '\(modelName)' is a :cloud-suffixed tag that routes to remote inference. BaseChatKit is local-first — strip the :cloud suffix or switch to a cloud backend (ClaudeBackend, OpenAIBackend) if remote inference is intended."
            )
        }

        // Honour the plan's effective context size so Ollama's `num_ctx`
        // matches what BCK's `ContextWindowManager` budgets against. If the
        // caller used the `.cloud()` factory (which defaults to 1), fall back
        // to the floor — Ollama's own 2048 default is a documented footgun
        // that silently truncates multi-turn conversations.
        let planned = plan.effectiveContextSize
        effectiveNumCtx = planned > Self.defaultNumCtxFloor ? planned : Self.defaultNumCtxFloor

        self.isThinkingModel = (try? await detectThinkingCapability()) ?? false

        setIsModelLoaded(true)
        Log.inference.info("OllamaBackend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public) thinking=\(self.isThinkingModel, privacy: .public) num_ctx=\(self.effectiveNumCtx, privacy: .public)")
    }

    /// Calls Ollama's `/api/show` endpoint and classifies the model as
    /// thinking-capable or not.
    ///
    /// Detection prefers `capabilities: ["thinking", ...]` (surfaced by modern
    /// Ollama releases) and falls back to scanning the Jinja `template` field
    /// for `<think>`, `</think>`, or `{{ if .Thinking }}` markers that
    /// reasoning models ship by convention.
    ///
    /// Returns `false` (not `nil`) on HTTP failures other than thrown network
    /// errors so callers get a clean boolean; `throws` so internal bugs (bad
    /// URL, serialization failure) still surface for the test harness.
    private func detectThinkingCapability() async throws -> Bool {
        guard let baseURL else { return false }
        let showURL = baseURL.appendingPathComponent("api/show")

        var request = URLRequest(url: showURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelName])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            Log.network.info("OllamaBackend /api/show probe failed (\(error.localizedDescription, privacy: .public)) — treating \(self.modelName, privacy: .public) as non-thinking")
            return false
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Log.network.info("OllamaBackend /api/show returned HTTP \(http.statusCode, privacy: .public) for \(self.modelName, privacy: .public) — treating as non-thinking")
            return false
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.network.info("OllamaBackend /api/show returned non-JSON for \(self.modelName, privacy: .public) — treating as non-thinking")
            return false
        }

        // Preferred: structured capabilities list.
        if let caps = json["capabilities"] as? [String],
           caps.contains(where: { $0.lowercased() == "thinking" }) {
            return true
        }

        // Fallback: scan the template for thinking markers.
        if let template = json["template"] as? String {
            let markers = ["<think>", "</think>", "{{ if .Thinking }}", "{{if .Thinking}}"]
            if markers.contains(where: { template.contains($0) }) {
                return true
            }
        }

        return false
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

        // num_predict has to cover thinking + visible tokens together on
        // Ollama. The three-state `maxThinkingTokens` semantics below map
        // directly to the wire:
        //
        //   nil → default thinking reserve, *only* on known thinking models
        //         (was unconditional pre-P4; non-thinking models no longer
        //         over-provision 2048 unused tokens).
        //   0   → explicitly disable thinking. Sends `think: false` on
        //         thinking-capable models; non-thinking models omit the key
        //         because Ollama treats it as a no-op there.
        //   N>0 → explicit cap at N thinking tokens; `think` is omitted so
        //         Ollama honours the model's per-request default and we stay
        //         forward-compatible with future capability flags.
        //
        // Visible output is still re-capped client-side in
        // parseResponseStream using the server's own `eval_count`, so an
        // over-generous num_predict can never cause more visible tokens than
        // `maxOutputTokens` to surface to the caller.
        let visibleBudget = config.maxOutputTokens ?? 2048
        let thinkingBudget: Int
        let thinkDirective: Bool?
        switch config.maxThinkingTokens {
        case .some(0):
            thinkingBudget = 0
            thinkDirective = isThinkingModel ? false : nil
        case .some(let n):
            thinkingBudget = n
            thinkDirective = nil
        case nil:
            thinkingBudget = isThinkingModel ? 2048 : 0
            thinkDirective = nil
        }

        let options: [String: Any] = [
            "temperature": config.temperature,
            "top_p": config.topP,
            "top_k": config.topK.map { Int($0) } ?? 40,
            "repeat_penalty": config.repeatPenalty,
            "num_predict": visibleBudget + thinkingBudget,
            // Ollama's server-side default is `OLLAMA_CONTEXT_LENGTH` (2048).
            // Multi-turn conversations with long history or tool results get
            // silently truncated at that ceiling with no error signal. Set
            // `num_ctx` explicitly to BCK's effective context size so the
            // server honours whatever budget we decided on at load time.
            "num_ctx": effectiveNumCtx,
        ]

        // TODO(#55): Tool calling for Ollama requires `stream: false`. Ollama
        // streaming silently drops `tool_calls` delta chunks, so when
        // `config.tools` is non-empty and tools land for this backend, this
        // body must switch `"stream"` to `false` and `parseResponseStream`
        // gains a non-streaming branch. See the Ollama tracking issue — the
        // workaround is well-documented upstream. Today `supportsToolCalling
        // == false` so `config.tools` is ignored by contract.
        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "options": options,
            "keep_alive": keepAlive,
        ]
        if config.jsonMode {
            body["format"] = "json"
        }
        if let think = thinkDirective {
            body["think"] = think
        }

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
    ///
    /// Fallback for models that leak reasoning into content: some Ollama
    /// models (e.g. Qwen3 tags that don't populate `message.thinking` on this
    /// server) emit `<think>…</think>` blocks inline in `content` instead.
    /// When we never see a populated `thinking` field on the stream and a
    /// content chunk contains the opening marker, content is routed through
    /// ``ThinkingParser`` so callers still receive
    /// ``GenerationEvent/thinkingToken(_:)`` /
    /// ``GenerationEvent/thinkingComplete`` events rather than the raw tags.
    /// The ``GenerationConfig/maxThinkingTokens`` cap still applies; visible
    /// content emerges from the parser as ``GenerationEvent/token(_:)``.
    ///
    /// Limitation: engagement is per-chunk, so an opening marker split across
    /// two NDJSON content chunks (e.g. `<th` + `ink>`) would miss detection
    /// and yield raw tag fragments as visible tokens. In practice Ollama
    /// emits `message.content` in coarse line-sized chunks, so the opening
    /// tag lands in a single chunk. Once engaged, the parser's own buffering
    /// correctly reassembles a closing tag split across chunks.
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

        // Inline `<think>` fallback state. Engaged only when the server never
        // populates `message.thinking` / top-level `thinking` and a content
        // chunk carries `<think>`. Once engaged it stays engaged for the rest
        // of the stream so partial tags split across chunks are held back
        // correctly by the parser's own buffering.
        var sawThinkingField = false
        let fallbackMarkers = config.thinkingMarkers ?? .qwen3
        var contentParser: ThinkingParser?

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

        // Yield a single parser-produced event while honouring the per-stream
        // caps used elsewhere. Returns `false` when the visible-token cap was
        // hit and the caller should stop producing further output on this
        // line. Only handles the events `ThinkingParser` actually emits
        // (`.token`, `.thinkingToken`, `.thinkingComplete`); anything else is
        // forwarded verbatim.
        func emit(_ event: GenerationEvent) throws -> Bool {
            switch event {
            case .thinkingToken(let text):
                if let limit = thinkingLimit, thinkingTokenCount >= limit {
                    return true // Drop silently — cap reached.
                }
                try noteEventYielded()
                continuation.yield(.thinkingToken(text))
                thinkingOpen = true
                thinkingTokenCount += 1
                return true
            case .thinkingComplete:
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
                return true
            case .token(let text):
                if let limit = visibleLimit, visibleLineCount >= limit {
                    continuation.finish()
                    return false
                }
                try noteEventYielded()
                continuation.yield(.token(text))
                visibleLineCount += 1
                return true
            default:
                continuation.yield(event)
                return true
            }
        }

        func handleLine(_ line: String) throws {
            guard let parsed = Self.parseLine(line) else { return }

            // Route thinking field (if any) first so downstream consumers see
            // reasoning before visible content for a given NDJSON record.
            if let thinking = parsed.thinking, !thinking.isEmpty {
                sawThinkingField = true
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
            } else if thinkingOpen && contentParser == nil {
                // Transition from thinking → content. Fire .thinkingComplete
                // exactly once on the first empty-thinking line we see after
                // any non-empty thinking was emitted. Skipped when the
                // fallback parser is driving state — the parser closes its
                // own thinking block via its own `.thinkingComplete`.
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

                // Engage the fallback `<think>`-in-content parser when the
                // server has never populated a dedicated thinking field on
                // this stream and the incoming content carries the opening
                // tag. Once engaged, every subsequent content chunk flows
                // through the parser so a tag split across two NDJSON lines
                // is held in the parser's own buffer.
                if contentParser == nil,
                   !sawThinkingField,
                   content.contains(fallbackMarkers.open) {
                    contentParser = ThinkingParser(markers: fallbackMarkers)
                }

                if var parser = contentParser {
                    for event in parser.process(content) {
                        if try !emit(event) {
                            contentParser = parser
                            return
                        }
                    }
                    contentParser = parser
                } else {
                    try noteEventYielded()
                    continuation.yield(.token(content))
                    visibleLineCount += 1
                }
            }

            if parsed.done {
                // Flush any remaining buffered content from the fallback
                // parser first — held-back bytes (e.g. an unmatched prefix
                // of `<`) must be emitted before we decide whether thinking
                // is still open.
                if var parser = contentParser {
                    for event in parser.finalize() {
                        if try !emit(event) {
                            contentParser = parser
                            return
                        }
                    }
                    contentParser = parser
                }

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

        // Drain any bytes still held back inside the fallback parser. A stream
        // that ends without a trailing done-chunk (network cut, malformed
        // last line) would otherwise swallow the final held-back suffix.
        if var parser = contentParser {
            for event in parser.finalize() {
                _ = try emit(event)
            }
            contentParser = parser
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

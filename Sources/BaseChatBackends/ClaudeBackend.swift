#if CloudSaaS
import Foundation
import os
import BaseChatInference

/// Anthropic Claude API inference backend.
///
/// Streams completions from the Anthropic Messages API (`/v1/messages`).
/// Handles Claude-specific SSE event types (`content_block_delta`, etc.)
/// and authentication via `x-api-key` header.
public final class ClaudeBackend: SSECloudBackend, TokenUsageProvider, CloudBackendKeychainConfigurable, StructuredHistoryReceiver, @unchecked Sendable {

    // MARK: - Init

    /// Creates a Claude backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    ///
    /// When `urlSession` is `nil` and the runtime kill-switch
    /// ``URLSessionProvider/networkDisabled`` is set, the underlying property
    /// access traps. Use ``makeChecked(urlSession:)`` for a throwing variant
    /// that surfaces the kill-switch as a recoverable error.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "claude-sonnet-4-20250514",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            payloadHandler: ClaudePayloadHandler()
        )
    }

    // MARK: - Structured History

    /// Structured replay history. Set by the coordinator when the caller
    /// uses ``InferenceService/enqueue(structuredMessages:...)``; carries
    /// the prior assistant turns' ``MessagePart/thinking(_:signature:)``
    /// blocks so the request body can include them with their signatures
    /// verbatim. Anthropic rejects multi-turn extended-thinking requests
    /// that drop or alter the signature.
    private var _structuredHistory: [StructuredMessage]?
    public var structuredHistory: [StructuredMessage]? {
        get { withStateLock { _structuredHistory } }
        set { withStateLock { _structuredHistory = newValue } }
    }

    public func setStructuredHistory(_ messages: [StructuredMessage]) {
        withStateLock { _structuredHistory = messages }
    }

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    ///
    /// - Parameter urlSession: Optional custom URLSession.
    /// - Throws: ``CloudBackendError/networkDisabled`` when the runtime
    ///   kill-switch is set and `urlSession` is `nil`.
    public static func makeChecked(urlSession: URLSession? = nil) throws -> ClaudeBackend {
        let session: URLSession
        if let urlSession {
            session = urlSession
        } else {
            session = try URLSessionProvider.throwingPinned()
        }
        return ClaudeBackend(urlSession: session)
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "Claude" }

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
            maxOutputTokens: 8192,
            supportsStreaming: true,
            isRemote: true
        )
    }

    // MARK: - Model Lifecycle

    // Plan is informational for cloud backends.
    public override func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }
        guard let key = resolveAPIKey(), !key.isEmpty else {
            throw CloudBackendError.missingAPIKey
        }
        setIsModelLoaded(true)
        Log.inference.info("Claude backend loaded (model: \(self.modelName))")
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
        guard let apiKey = resolveAPIKey(), !apiKey.isEmpty else {
            throw CloudBackendError.missingAPIKey
        }

        let messagesURL = baseURL.appendingPathComponent("v1/messages")

        // Prefer the structured history when the coordinator provided one —
        // it carries thinking blocks with signatures so multi-turn extended
        // thinking replay works correctly. Fall back to the flattened
        // (role, content) history for non-thinking conversations or callers
        // using the legacy entry points.
        let chatMessages: [[String: Any]]
        if let structured = structuredHistory, !structured.isEmpty {
            chatMessages = structured.map(Self.encodeMessageContent(for:))
        } else if let history = conversationHistory {
            chatMessages = history.map { ["role": $0.role, "content": $0.content] }
        } else {
            chatMessages = [["role": "user", "content": prompt]]
        }

        var body: [String: Any] = [
            "model": modelName,
            "max_tokens": config.maxOutputTokens ?? 2048,
            "messages": chatMessages,
            "stream": true,
            "temperature": config.temperature,
            "top_p": config.topP
        ]

        if let systemPrompt, !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }

        // Enable extended thinking when the caller asked for a thinking budget.
        // Anthropic requires the budget to be strictly less than max_tokens and
        // temperature to be 1.0 when thinking is enabled; surface a clamped
        // request rather than silently dropping the parameter.
        if let budget = config.maxThinkingTokens, budget > 0 {
            let maxTokens = (body["max_tokens"] as? Int) ?? 2048
            let clampedBudget = min(budget, max(1024, maxTokens - 1))
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": clampedBudget
            ] as [String: Any]
            body["temperature"] = 1.0
        }

        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        // Generous timeout for streaming — covers inter-packet gaps during slow generation.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }

    // MARK: - Structured Content Encoding

    /// Encodes one ``StructuredMessage`` as an Anthropic Messages API
    /// `messages[]` entry.
    ///
    /// - User turns collapse to a plain string `content` for simplicity —
    ///   Anthropic accepts either a string or a structured array on user
    ///   role.
    /// - Assistant turns serialize to a structured `content` array. Thinking
    ///   blocks are emitted **before** any text block, with their
    ///   ``MessagePart/thinkingSignature`` carried verbatim. Anthropic's
    ///   multi-turn extended-thinking contract requires the signature to
    ///   match what the model emitted on the previous turn, so any
    ///   thinking block missing a signature is dropped rather than sent
    ///   with a blank one (which would 400).
    /// - System / tool turns fall back to plain string content.
    static func encodeMessageContent(for message: StructuredMessage) -> [String: Any] {
        if message.role == "assistant" {
            var blocks: [[String: Any]] = []

            // Thinking blocks first — Anthropic requires thinking content to
            // precede any text/tool_use within the same assistant turn.
            for part in message.parts {
                if case .thinking(let text, let signature) = part {
                    // Signature-less thinking blocks (legacy persisted rows
                    // that pre-date #604, or local backends like MLX/Llama
                    // where Anthropic never issued one) are dropped from the
                    // replay payload. Sending them blank would fail the
                    // server-side signature check and 400 the request.
                    guard let signature else { continue }
                    blocks.append([
                        "type": "thinking",
                        "thinking": text,
                        "signature": signature
                    ])
                }
            }

            // Then text. Concatenated into a single block to match how the
            // model originally emitted its visible content.
            let visible = message.textContent
            if !visible.isEmpty {
                blocks.append([
                    "type": "text",
                    "text": visible
                ])
            }

            // An assistant turn with neither thinking nor text would 400.
            // Emit a single empty text block in that pathological case so
            // the wire shape is still valid and the server returns a normal
            // error rather than a stream-level parse failure.
            if blocks.isEmpty {
                return ["role": "assistant", "content": ""]
            }
            return ["role": "assistant", "content": blocks]
        }

        // User and other roles: collapse to plain text.
        return ["role": message.role, "content": message.textContent]
    }

    /// Claude reports usage split across `message_start` (prompt) and
    /// `message_delta` (completion), so we merge incrementally.
    public override func handleUsage(_ usage: (promptTokens: Int?, completionTokens: Int?)) {
        if let promptTokens = usage.promptTokens {
            lastUsage = (promptTokens: promptTokens, completionTokens: 0)
        } else if let completionTokens = usage.completionTokens {
            let existing = lastUsage?.promptTokens ?? 0
            lastUsage = (promptTokens: existing, completionTokens: completionTokens)
        }
    }

    // MARK: - Stream Parsing

    /// Parses Claude's SSE response with extended-thinking support.
    ///
    /// Anthropic interleaves reasoning and visible content via typed content
    /// blocks. A typical extended-thinking response looks like:
    ///
    /// ```
    /// content_block_start {index:0, content_block:{type:"thinking"}}
    /// content_block_delta {index:0, delta:{type:"thinking_delta", thinking:"..."}}
    /// content_block_stop  {index:0}
    /// content_block_start {index:1, content_block:{type:"text"}}
    /// content_block_delta {index:1, delta:{type:"text_delta",     text:"..."}}
    /// content_block_stop  {index:1}
    /// message_stop
    /// ```
    ///
    /// We route `thinking_delta` chunks to ``GenerationEvent/thinkingToken(_:)``
    /// and emit a single ``GenerationEvent/thinkingComplete`` exactly once — on
    /// the first transition from a thinking block to any non-thinking event
    /// (text block start, token, usage, or terminal stop). Non-reasoning
    /// responses never fire `.thinkingComplete` because no thinking chunk was
    /// ever observed.
    ///
    /// Anthropic's extended-thinking blocks also carry an opaque
    /// `signature` — required verbatim on multi-turn replay. We surface it
    /// as ``GenerationEvent/thinkingSignature(_:)``, captured from either
    /// the `content_block_start` payload or a nested
    /// `signature_delta` (the path real production streams use today).
    /// See #604.
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let tokenStream = SSEStreamParser.parse(bytes: bytes, limits: effectiveSSEStreamLimits)

        // `thinkingOpen` flips to true the first time we see a thinking_delta.
        // It flips back to false — and fires .thinkingComplete exactly once —
        // the first time we see anything that clearly isn't thinking anymore.
        var thinkingOpen = false

        func flushThinkingCompleteIfNeeded() {
            if thinkingOpen {
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
            }
        }

        for try await payload in tokenStream {
            if Task.isCancelled { break }

            let eventType = Self.parseEventType(from: payload)

            // Thinking-block start: opportunistically capture the signature
            // if Anthropic shipped one inline on the start event. Real
            // streams more commonly carry the signature on a later
            // `signature_delta`, but a couple of beta endpoints attach it
            // here, and the redundant emission is harmless — UI consumers
            // overwrite stored signatures rather than appending.
            if eventType == "content_block_start", let signature = Self.parseThinkingBlockStartSignature(from: payload) {
                continuation.yield(.thinkingSignature(signature))
                continue
            }

            // Signature delta inside the thinking block. This is the
            // primary path Anthropic uses today for extended-thinking
            // signatures — the field arrives via a `signature_delta`
            // sub-type of `content_block_delta`. Surface it to the UI so
            // multi-turn replay can preserve the exact bytes verbatim.
            if eventType == "content_block_delta", let signature = Self.parseSignatureDelta(from: payload) {
                continuation.yield(.thinkingSignature(signature))
                continue
            }

            // Thinking delta: emit as thinkingToken, keep the block open.
            if eventType == "content_block_delta", let thinking = Self.parseThinkingDelta(from: payload) {
                continuation.yield(.thinkingToken(thinking))
                thinkingOpen = true
                continue
            }

            // Plain text delta: close any open thinking block first, then yield.
            if let token = extractToken(from: payload) {
                flushThinkingCompleteIfNeeded()
                continuation.yield(.token(token))
            }

            if let usage = extractUsage(from: payload) {
                handleUsage(usage)
                if let prompt = usage.promptTokens,
                   let completion = usage.completionTokens {
                    continuation.yield(.usage(prompt: prompt, completion: completion))
                }
            }

            if isStreamEnd(payload) {
                flushThinkingCompleteIfNeeded()
                break
            }

            if let error = extractStreamError(from: payload) {
                throw error
            }
        }

        // Safety net: stream ended without a text block or message_stop while
        // still inside a thinking block (truncated upstream). Close the block
        // so consumers don't hang in a thinking-only state.
        flushThinkingCompleteIfNeeded()
    }

    // MARK: - HTTP Status Validation

    public override func checkStatusCode(
        _ response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        let statusCode = response.statusCode

        switch statusCode {
        case 200...299:
            return
        case 401, 403:
            throw CloudBackendError.authenticationFailed(provider: "Claude")
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CloudBackendError.rateLimited(retryAfter: retryAfter)
        default:
            let errorBody = await Self.readErrorBody(from: bytes)
            Log.network.debug("Claude upstream error body: \(errorBody, privacy: .private)")
            let host = self.baseURL?.host()
            let sanitized = CloudErrorSanitizer.sanitize(
                extractErrorMessage(from: errorBody),
                host: host
            )
            throw CloudBackendError.serverError(
                statusCode: statusCode,
                message: sanitized
            )
        }
    }

    /// Reads up to 1000 characters from the byte stream for error diagnostics.
    private static func readErrorBody(from bytes: URLSession.AsyncBytes) async -> String {
        var body = ""
        do {
            for try await byte in bytes {
                body.append(Character(UnicodeScalar(byte)))
                if body.count > 1000 { break }
            }
        } catch {
            // Best-effort — partial body is fine for error messages.
        }
        return body
    }

    // MARK: - SSE Payload Handler

    /// Claude-specific SSE payload interpreter for use with `SSEStreamParser.streamTokens`.
    static let payloadHandler = ClaudePayloadHandler()

    struct ClaudePayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            ClaudeBackend.parseToken(from: payload)
        }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            ClaudeBackend.parseUsage(from: payload)
        }
        func isStreamEnd(_ payload: String) -> Bool {
            ClaudeBackend.parseIsStreamEnd(payload)
        }
        func extractStreamError(from payload: String) -> Error? {
            ClaudeBackend.parseStreamError(from: payload)
        }
    }

    // MARK: - JSON Parsing

    /// Returns the `type` field of an Anthropic SSE event payload, if any.
    static func parseEventType(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed["type"] as? String
    }

    /// Extracts the `.signature` field from a thinking-block
    /// `content_block_start` payload, when present.
    ///
    /// Shape: `{type:"content_block_start", content_block:{type:"thinking", signature:"..."}}`.
    /// Returns `nil` for non-thinking blocks or starts that don't carry a
    /// signature.
    static func parseThinkingBlockStartSignature(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "content_block_start",
              let block = parsed["content_block"] as? [String: Any],
              block["type"] as? String == "thinking",
              let signature = block["signature"] as? String,
              !signature.isEmpty else {
            return nil
        }
        return signature
    }

    /// Extracts the `.signature` from a `signature_delta` event nested
    /// inside a `content_block_delta`. Anthropic emits the extended-thinking
    /// signature via this path on most production responses.
    ///
    /// Shape: `{type:"content_block_delta", delta:{type:"signature_delta", signature:"..."}}`.
    static func parseSignatureDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              delta["type"] as? String == "signature_delta",
              let signature = delta["signature"] as? String,
              !signature.isEmpty else {
            return nil
        }
        return signature
    }

    /// Extracts the `.thinking` text from a `thinking_delta` content-block delta.
    ///
    /// Anthropic extended-thinking responses carry reasoning as a separate
    /// content-block type. The delta shape is
    /// `{type:"content_block_delta", delta:{type:"thinking_delta", thinking:"..."}}`.
    static func parseThinkingDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              delta["type"] as? String == "thinking_delta",
              let thinking = delta["thinking"] as? String else {
            return nil
        }
        return thinking
    }

    /// Extracts a text token from a `content_block_delta` event payload.
    static func parseToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    /// Returns `true` if the SSE payload signals end of stream.
    private static func parseIsStreamEnd(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = parsed["type"] as? String else {
            return false
        }
        return type == "message_stop"
    }

    /// Extracts token usage from Claude SSE event payloads.
    ///
    /// `message_start` contains `input_tokens`, `message_delta` contains `output_tokens`.
    private static func parseUsage(from json: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = parsed["type"] as? String else {
            return nil
        }

        switch type {
        case "message_start":
            guard let message = parsed["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let inputTokens = usage["input_tokens"] as? Int else {
                return nil
            }
            return (promptTokens: inputTokens, completionTokens: nil)

        case "message_delta":
            guard let usage = parsed["usage"] as? [String: Any],
                  let outputTokens = usage["output_tokens"] as? Int else {
                return nil
            }
            return (promptTokens: nil, completionTokens: outputTokens)

        default:
            return nil
        }
    }

    /// Extracts an error from an SSE `error` event payload.
    private static func parseStreamError(from json: String) -> CloudBackendError? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "error",
              let error = parsed["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return .parseError(message)
    }
}
#endif


import Foundation
import os
import BaseChatInference

/// Anthropic Claude API inference backend.
///
/// Streams completions from the Anthropic Messages API (`/v1/messages`).
/// Handles Claude-specific SSE event types (`content_block_delta`, etc.)
/// and authentication via `x-api-key` header.
public final class ClaudeBackend: SSECloudBackend, TokenUsageProvider, CloudBackendKeychainConfigurable, @unchecked Sendable {

    // MARK: - Init

    /// Creates a Claude backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "claude-sonnet-4-20250514",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            payloadHandler: ClaudePayloadHandler()
        )
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

        let chatMessages: [[String: String]]
        if let history = conversationHistory {
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

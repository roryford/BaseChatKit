import Foundation
import os
import BaseChatCore

/// Anthropic Claude API inference backend.
///
/// Streams completions from the Anthropic Messages API (`/v1/messages`).
/// Handles Claude-specific SSE event types (`content_block_delta`, etc.)
/// and authentication via `x-api-key` header.
public final class ClaudeBackend: SSECloudBackend, TokenUsageProvider, CloudBackendKeychainConfigurable {

    /// Shared session with certificate pinning delegate.
    private static let pinnedSession: URLSession = {
        let delegate = PinnedSessionDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    // MARK: - Init

    /// Creates a Claude backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "claude-sonnet-4-20250514",
            urlSession: urlSession ?? Self.pinnedSession
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
            supportsToolCalling: true,
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

    public override func loadModel(from url: URL, contextSize: Int32) async throws {
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
            "max_tokens": config.maxOutputTokens ?? Int(config.maxTokens),
            "messages": chatMessages,
            "stream": true,
            "temperature": config.temperature,
            "top_p": config.topP
        ]

        if let systemPrompt, !systemPrompt.isEmpty {
            body["system"] = systemPrompt
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

    // MARK: - SSE Payload Handling

    public override func extractToken(from payload: String) -> String? {
        Self.parseToken(from: payload)
    }

    public override func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        Self.parseUsage(from: payload)
    }

    public override func isStreamEnd(_ payload: String) -> Bool {
        Self.parseIsStreamEnd(payload)
    }

    public override func extractStreamError(from payload: String) -> Error? {
        Self.parseStreamError(from: payload)
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
            throw CloudBackendError.serverError(
                statusCode: statusCode,
                message: extractErrorMessage(from: errorBody) ?? "Unknown error"
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

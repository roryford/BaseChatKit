import Foundation
import os
import BaseChatCore

/// Anthropic Claude API inference backend.
///
/// Streams completions from the Anthropic Messages API (`/v1/messages`).
/// Handles Claude-specific SSE event types (`content_block_delta`, etc.)
/// and authentication via `x-api-key` header.
public final class ClaudeBackend: InferenceBackend, ConversationHistoryReceiver, TokenUsageProvider, @unchecked Sendable {

    // MARK: - Logging

    private static let inferenceLogger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )
    private static let networkLogger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "network"
    )

    // MARK: - State

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    /// Full conversation history for multi-turn support.
    /// Set by InferenceService before each generate call.
    public var conversationHistory: [(role: String, content: String)]?

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        conversationHistory = messages
    }

    // MARK: - Capabilities

    public var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 200_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )
    }

    // MARK: - Configuration

    private var baseURL: URL?
    /// Keychain account identifier for just-in-time API key retrieval.
    /// The raw key is never held in memory as a stored property.
    private var keychainAccount: String?
    /// Fallback API key for tests or ephemeral use. Prefer `keychainAccount`.
    private var ephemeralAPIKey: String?
    private var modelName: String = "claude-sonnet-4-20250514"

    /// Token usage from the most recent generation, if available.
    public private(set) var lastUsage: (promptTokens: Int, completionTokens: Int)?

    // MARK: - Private

    private var currentTask: Task<Void, Never>?
    private let urlSession: URLSession

    /// Shared session with certificate pinning delegate.
    private static let pinnedSession: URLSession = {
        let delegate = PinnedSessionDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    // MARK: - Init

    /// Creates a Claude backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    public init(urlSession: URLSession? = nil) {
        self.urlSession = urlSession ?? Self.pinnedSession
    }

    // MARK: - Configuration

    /// Configures the backend with connection details.
    ///
    /// Call this before `loadModel(from:contextSize:)`.
    /// - Parameters:
    ///   - baseURL: Anthropic API base URL (e.g. `https://api.anthropic.com`).
    ///   - apiKey: API key for ephemeral/test use. Prefer `configure(baseURL:keychainAccount:modelName:)`.
    ///   - modelName: Model identifier (e.g. `claude-sonnet-4-20250514`).
    public func configure(baseURL: URL, apiKey: String?, modelName: String) {
        self.baseURL = baseURL
        self.ephemeralAPIKey = apiKey
        self.keychainAccount = nil
        self.modelName = modelName
    }

    /// Configures the backend with a Keychain-backed API key.
    ///
    /// The API key is read from the Keychain just-in-time for each request,
    /// avoiding holding secrets in memory between requests.
    /// - Parameters:
    ///   - baseURL: Anthropic API base URL (e.g. `https://api.anthropic.com`).
    ///   - keychainAccount: The Keychain account identifier (from `APIEndpoint.keychainAccount`).
    ///   - modelName: Model identifier (e.g. `claude-sonnet-4-20250514`).
    public func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        self.baseURL = baseURL
        self.keychainAccount = keychainAccount
        self.ephemeralAPIKey = nil
        self.modelName = modelName
    }

    /// Retrieves the API key from Keychain or ephemeral storage.
    private func resolveAPIKey() -> String? {
        if let keychainAccount {
            return KeychainService.retrieve(account: keychainAccount)
        }
        return ephemeralAPIKey
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }
        guard let key = resolveAPIKey(), !key.isEmpty else {
            throw CloudBackendError.missingAPIKey
        }
        isModelLoaded = true
        Self.inferenceLogger.info("Claude backend loaded (model: \(self.modelName))")
    }

    public func unloadModel() {
        stopGeneration()
        baseURL = nil
        keychainAccount = nil
        ephemeralAPIKey = nil
        isModelLoaded = false
        Self.inferenceLogger.info("Claude backend unloaded")
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded, let baseURL else {
            throw CloudBackendError.invalidURL("Backend not configured")
        }
        // Resolve the API key just-in-time from Keychain or ephemeral storage.
        guard let apiKey = resolveAPIKey(), !apiKey.isEmpty else {
            throw CloudBackendError.missingAPIKey
        }

        isGenerating = true
        lastUsage = nil
        Self.networkLogger.debug("Claude generate started (model: \(self.modelName))")

        let request = try buildRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )

        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let session = self.urlSession
            let task = Task { [weak self] in
                defer {
                    self?.isGenerating = false
                    Self.networkLogger.debug("Claude generate finished")
                }

                do {
                    try await withExponentialBackoff {
                        let (bytes, response) = try await session.bytes(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw CloudBackendError.networkError(
                                underlying: URLError(.badServerResponse)
                            )
                        }

                        try await Self.validateStatusCode(httpResponse, bytes: bytes)

                        let sseStream = SSEStreamParser.parse(bytes: bytes)

                        for try await payload in sseStream {
                            if Task.isCancelled { break }

                            if let token = Self.extractToken(from: payload) {
                                continuation.yield(token)
                            }

                            if let usage = Self.extractUsage(from: payload) {
                                if let promptTokens = usage.promptTokens {
                                    // message_start: capture prompt count; completionTokens fills in later.
                                    self?.lastUsage = (promptTokens: promptTokens, completionTokens: 0)
                                } else if let completionTokens = usage.completionTokens {
                                    // message_delta: merge with already-stored prompt count so a mid-stream
                                    // drop still preserves whatever partial counts we have.
                                    let existing = self?.lastUsage?.promptTokens ?? 0
                                    self?.lastUsage = (promptTokens: existing, completionTokens: completionTokens)
                                }
                            }

                            if Self.isStreamEnd(payload) {
                                break
                            }

                            if let error = Self.extractStreamError(from: payload) {
                                throw error
                            }
                        }
                    }

                    continuation.finish()

                } catch {
                    if !Task.isCancelled {
                        Self.networkLogger.error("Claude stream error: \(error, privacy: .private)")
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }

            self.currentTask = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Control

    public func stopGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
    }

    // MARK: - Request Building

    private func buildRequest(
        baseURL: URL,
        apiKey: String,
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> URLRequest {
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

    // MARK: - Response Validation

    private static func validateStatusCode(
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
            let errorBody = await readErrorBody(from: bytes)
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
            ClaudeBackend.extractToken(from: payload)
        }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            ClaudeBackend.extractUsage(from: payload)
        }
        func isStreamEnd(_ payload: String) -> Bool {
            ClaudeBackend.isStreamEnd(payload)
        }
        func extractStreamError(from payload: String) -> Error? {
            ClaudeBackend.extractStreamError(from: payload)
        }
    }

    // MARK: - SSE Payload Parsing

    /// Extracts a text token from a `content_block_delta` event payload.
    static func extractToken(from json: String) -> String? {
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
    private static func isStreamEnd(_ json: String) -> Bool {
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
    private static func extractUsage(from json: String) -> (promptTokens: Int?, completionTokens: Int?)? {
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
    private static func extractStreamError(from json: String) -> CloudBackendError? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "error",
              let error = parsed["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return .parseError(message)
    }

    /// Extracts the error message from an Anthropic JSON error response body.
    private static func extractErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = parsed["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}

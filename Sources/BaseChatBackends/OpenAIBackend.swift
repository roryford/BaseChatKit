import Foundation
import os
import BaseChatCore

/// Cloud inference backend using the OpenAI Chat Completions API.
///
/// Compatible with OpenAI, Ollama, LM Studio, and any OpenAI-compatible endpoint.
/// Streams responses via Server-Sent Events (SSE).
///
/// Usage:
/// ```swift
/// let backend = OpenAIBackend()
/// backend.configure(
///     baseURL: URL(string: "https://api.openai.com")!,
///     apiKey: "sk-...",
///     modelName: "gpt-4o-mini"
/// )
/// try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await token in stream { print(token, terminator: "") }
/// ```
public final class OpenAIBackend: InferenceBackend, ConversationHistoryReceiver, TokenUsageProvider, CloudBackendURLModelConfigurable, CloudBackendKeychainConfigurable, @unchecked Sendable {

    // MARK: - Logging

    private static let inferenceLogger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )
    private static let networkLogger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "network"
    )

    // MARK: - Configuration

    private var baseURL: URL?
    /// Keychain account identifier for just-in-time API key retrieval.
    private var keychainAccount: String?
    /// Fallback API key for tests or ephemeral use. Prefer `keychainAccount`.
    private var ephemeralAPIKey: String?
    private var modelName: String = "gpt-4o-mini"

    // MARK: - State

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    /// Full conversation history for multi-turn support.
    /// Set by InferenceService before each generate call.
    public var conversationHistory: [(role: String, content: String)]?

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        conversationHistory = messages
    }

    public var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 128_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external
        )
    }

    /// Token usage from the most recent generation, if available.
    public private(set) var lastUsage: (promptTokens: Int, completionTokens: Int)?

    private var currentTask: Task<Void, Never>?
    private let urlSession: URLSession

    /// Shared session with certificate pinning delegate.
    private static let pinnedSession: URLSession = {
        let delegate = PinnedSessionDelegate()
        let config = URLSessionConfiguration.default
        // 300s covers inter-packet gaps during slow LLM generation; 600s caps total resource time.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    // MARK: - Init

    /// Creates an OpenAI-compatible backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    public init(urlSession: URLSession? = nil) {
        self.urlSession = urlSession ?? Self.pinnedSession
    }

    // MARK: - Configuration

    /// Configures the backend with connection details. Call before ``loadModel(from:contextSize:)``.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL of the API server (e.g. `https://api.openai.com`).
    ///              The `/v1/chat/completions` path is appended automatically.
    ///   - apiKey: API key for ephemeral/test use. Pass `nil` for local servers
    ///             (Ollama, LM Studio) that don't require auth.
    ///   - modelName: The model identifier (e.g. `"gpt-4o-mini"`, `"llama3"`, `"local-model"`).
    public func configure(baseURL: URL, apiKey: String?, modelName: String) {
        self.baseURL = baseURL
        self.ephemeralAPIKey = apiKey
        self.keychainAccount = nil
        self.modelName = modelName
    }

    /// Configures the backend with a Keychain-backed API key.
    ///
    /// The API key is read from the Keychain just-in-time for each request.
    public func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        self.baseURL = baseURL
        self.keychainAccount = keychainAccount
        self.ephemeralAPIKey = nil
        self.modelName = modelName
    }

    /// Configures the backend for OpenAI-compatible servers that do not require API keys.
    public func configure(baseURL: URL, modelName: String) {
        configure(baseURL: baseURL, apiKey: nil, modelName: modelName)
    }

    /// Retrieves the API key from Keychain or ephemeral storage.
    private func resolveAPIKey() -> String? {
        if let keychainAccount {
            return KeychainService.retrieve(account: keychainAccount)
        }
        return ephemeralAPIKey
    }

    // MARK: - InferenceBackend

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:apiKey:modelName:) first."
            )
        }
        isModelLoaded = true
        Self.inferenceLogger.info("OpenAI backend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public)")
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded, let baseURL else {
            throw CloudBackendError.invalidURL("Backend not configured. Call loadModel first.")
        }

        let request = try buildRequest(
            baseURL: baseURL,
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )

        isGenerating = true
        lastUsage = nil

        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: CloudBackendError.streamInterrupted)
                return
            }

            let session = self.urlSession

            let task = Task { [weak self] in
                defer { self?.isGenerating = false }

                do {
                    try await withExponentialBackoff {
                        let (bytes, response) = try await session.bytes(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw CloudBackendError.networkError(
                                underlying: URLError(.badServerResponse)
                            )
                        }

                        try await Self.checkStatusCode(httpResponse, bytes: bytes)

                        let tokenStream = SSEStreamParser.parse(bytes: bytes)
                        for try await payload in tokenStream {
                            if Task.isCancelled { break }

                            if let token = Self.extractToken(from: payload) {
                                continuation.yield(token)
                            }

                            if let usage = Self.extractUsage(from: payload) {
                                self?.lastUsage = usage
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        Self.networkLogger.error("OpenAI stream error: \(error.localizedDescription, privacy: .private)")
                        continuation.finish(throwing: error)
                    }
                }
            }

            self.currentTask = task

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func stopGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
    }

    public func unloadModel() {
        stopGeneration()
        baseURL = nil
        keychainAccount = nil
        ephemeralAPIKey = nil
        isModelLoaded = false
        Self.inferenceLogger.info("OpenAI backend unloaded")
    }

    // MARK: - Request Building

    private func buildRequest(
        baseURL: URL,
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> URLRequest {
        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")

        var messages: [[String: String]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        if let history = conversationHistory {
            messages.append(contentsOf: history.map { ["role": $0.role, "content": $0.content] })
        } else {
            messages.append(["role": "user", "content": prompt])
        }

        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": config.temperature,
            "top_p": config.topP,
            "max_tokens": config.maxOutputTokens ?? Int(config.maxTokens)
        ]

        var request = URLRequest(url: completionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Resolve API key just-in-time from Keychain or ephemeral storage.
        if let apiKey = resolveAPIKey(), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Self.networkLogger.debug("OpenAI request to \(completionsURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - Response Handling

    /// Checks the HTTP status code and throws an appropriate error for non-2xx responses.
    private static func checkStatusCode(
        _ response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        let statusCode = response.statusCode

        guard !(200...299).contains(statusCode) else { return }

        switch statusCode {
        case 401, 403:
            throw CloudBackendError.authenticationFailed(provider: "OpenAI-compatible")
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CloudBackendError.rateLimited(retryAfter: retryAfter)
        default:
            // Read up to 2KB of the error body for diagnostics
            var errorBody = ""
            for try await byte in bytes {
                errorBody.append(Character(UnicodeScalar(byte)))
                if errorBody.count > 2048 { break }
            }
            let message = extractErrorMessage(from: errorBody) ?? "Unexpected server error (status \(statusCode))"
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
    }

    // MARK: - SSE Payload Handler

    /// OpenAI-specific SSE payload interpreter for use with `SSEStreamParser.streamTokens`.
    static let payloadHandler = OpenAIPayloadHandler()

    struct OpenAIPayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            OpenAIBackend.extractToken(from: payload)
        }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            guard let usage = OpenAIBackend.extractUsage(from: payload) else { return nil }
            return (promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
        }
        func isStreamEnd(_ payload: String) -> Bool { false }
        func extractStreamError(from payload: String) -> Error? { nil }
    }

    // MARK: - JSON Parsing

    /// Extracts the content token from an OpenAI streaming response chunk.
    ///
    /// Expected format:
    /// ```json
    /// {"choices":[{"delta":{"content":"token"}}]}
    /// ```
    private static func extractToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }

    /// Extracts token usage from an OpenAI streaming response chunk.
    ///
    /// The final chunk includes usage when `stream_options.include_usage` is set:
    /// ```json
    /// {"choices":[...],"usage":{"prompt_tokens":25,"completion_tokens":100,"total_tokens":125}}
    /// ```
    private static func extractUsage(from json: String) -> (promptTokens: Int, completionTokens: Int)? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = parsed["usage"] as? [String: Any],
              let prompt = usage["prompt_tokens"] as? Int,
              let completion = usage["completion_tokens"] as? Int else {
            return nil
        }
        return (prompt, completion)
    }

    /// Extracts an error message from an OpenAI-format error response body.
    ///
    /// Expected format:
    /// ```json
    /// {"error":{"message":"You exceeded your current quota..."}}
    /// ```
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

import Foundation
import os
import BaseChatCore

/// Base class for cloud inference backends that stream responses via Server-Sent Events.
///
/// Centralises the stream lifecycle, task management, exponential backoff retry,
/// SSE parsing, and thread-safe state management that OpenAI, Claude, and KoboldCpp
/// backends all share. Subclasses provide API-specific request building, token
/// extraction, and capability declarations.
///
/// Thread safety uses `NSLock` (via ``withStateLock(_:)``) rather than
/// `@unchecked Sendable` on each subclass individually.
open class SSECloudBackend: InferenceBackend, ConversationHistoryReceiver, @unchecked Sendable {

    // MARK: - Lock

    private let stateLock = NSLock()

    /// Executes a closure while holding the state lock.
    @discardableResult
    public func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - State

    private var _isModelLoaded = false
    public var isModelLoaded: Bool {
        withStateLock { _isModelLoaded }
    }

    private var _isGenerating = false
    public var isGenerating: Bool {
        withStateLock { _isGenerating }
    }

    private var _baseURL: URL?
    /// The configured API base URL.
    public var baseURL: URL? {
        get { withStateLock { _baseURL } }
        set { withStateLock { _baseURL = newValue } }
    }

    private var _modelName: String
    /// The configured model identifier.
    public var modelName: String {
        get { withStateLock { _modelName } }
        set { withStateLock { _modelName = newValue } }
    }

    private var _keychainAccount: String?
    /// Keychain account identifier for just-in-time API key retrieval.
    public var keychainAccount: String? {
        get { withStateLock { _keychainAccount } }
        set { withStateLock { _keychainAccount = newValue } }
    }

    private var _ephemeralAPIKey: String?
    /// Fallback API key for tests or ephemeral use. Prefer ``keychainAccount``.
    public var ephemeralAPIKey: String? {
        get { withStateLock { _ephemeralAPIKey } }
        set { withStateLock { _ephemeralAPIKey = newValue } }
    }

    private var _conversationHistory: [(role: String, content: String)]?
    /// Full conversation history for multi-turn support.
    public var conversationHistory: [(role: String, content: String)]? {
        get { withStateLock { _conversationHistory } }
        set { withStateLock { _conversationHistory = newValue } }
    }

    private var _lastUsage: (promptTokens: Int, completionTokens: Int)?
    /// Token usage from the most recent generation, if available.
    public var lastUsage: (promptTokens: Int, completionTokens: Int)? {
        get { withStateLock { _lastUsage } }
        set { withStateLock { _lastUsage = newValue } }
    }

    private var currentTask: Task<Void, Never>?

    public let urlSession: URLSession

    // MARK: - Init

    /// Creates an SSE cloud backend.
    ///
    /// - Parameters:
    ///   - defaultModelName: The default model identifier for this backend.
    ///   - urlSession: URLSession to use for network requests.
    public init(defaultModelName: String, urlSession: URLSession) {
        self._modelName = defaultModelName
        self.urlSession = urlSession
    }

    // MARK: - Subclass Hooks

    /// Human-readable backend name for logging (e.g. "OpenAI", "Claude").
    open var backendName: String { "SSECloud" }

    /// The backend's capability declaration.
    open var capabilities: BackendCapabilities {
        fatalError("Subclasses must override capabilities")
    }

    /// Builds the URLRequest for a generation call.
    ///
    /// Called by ``generate(prompt:systemPrompt:config:)`` after validating state.
    /// Subclasses must override to produce the API-specific request format.
    open func buildRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> URLRequest {
        fatalError("Subclasses must override buildRequest")
    }

    /// Extracts a text token from an SSE JSON payload.
    ///
    /// Return `nil` if the payload does not contain a token.
    open func extractToken(from payload: String) -> String? {
        fatalError("Subclasses must override extractToken")
    }

    /// Extracts token usage from an SSE JSON payload.
    ///
    /// Return `nil` if the payload does not contain usage information.
    /// Either component can be `nil` for APIs that report usage in multiple events.
    open func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        nil
    }

    /// Returns `true` if the payload signals end of stream.
    ///
    /// Most APIs use `[DONE]` which SSEStreamParser handles automatically.
    /// Override for APIs with explicit stop events (e.g. Claude's `message_stop`).
    open func isStreamEnd(_ payload: String) -> Bool {
        false
    }

    /// Extracts an in-stream error from an SSE JSON payload.
    ///
    /// Override for APIs that report errors as SSE events (e.g. Claude).
    open func extractStreamError(from payload: String) -> Error? {
        nil
    }

    /// Called by ``generate(prompt:systemPrompt:config:)`` to update usage state.
    ///
    /// The default implementation sets ``lastUsage`` directly. Claude overrides
    /// this to merge split prompt/completion counts across multiple events.
    open func handleUsage(_ usage: (promptTokens: Int?, completionTokens: Int?)) {
        if let prompt = usage.promptTokens, let completion = usage.completionTokens {
            lastUsage = (promptTokens: prompt, completionTokens: completion)
        } else if let prompt = usage.promptTokens {
            lastUsage = (promptTokens: prompt, completionTokens: lastUsage?.completionTokens ?? 0)
        } else if let completion = usage.completionTokens {
            lastUsage = (promptTokens: lastUsage?.promptTokens ?? 0, completionTokens: completion)
        }
    }

    // MARK: - Shared Configuration

    /// Configures the backend with connection details.
    public func configure(baseURL: URL, apiKey: String?, modelName: String) {
        withStateLock {
            _baseURL = baseURL
            _ephemeralAPIKey = apiKey
            _keychainAccount = nil
            _modelName = modelName
        }
    }

    /// Configures the backend with a Keychain-backed API key.
    public func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        withStateLock {
            _baseURL = baseURL
            _keychainAccount = keychainAccount
            _ephemeralAPIKey = nil
            _modelName = modelName
        }
    }

    /// Configures the backend without an API key (for local servers).
    public func configure(baseURL: URL, modelName: String) {
        configure(baseURL: baseURL, apiKey: nil, modelName: modelName)
    }

    /// Retrieves the API key from Keychain or ephemeral storage.
    public func resolveAPIKey() -> String? {
        let (account, ephemeral) = withStateLock { (_keychainAccount, _ephemeralAPIKey) }
        if let account {
            return KeychainService.retrieve(account: account)
        }
        return ephemeral
    }

    // MARK: - ConversationHistoryReceiver

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        withStateLock { _conversationHistory = messages }
    }

    // MARK: - Model Lifecycle

    /// Sets `isModelLoaded` to `true`.
    ///
    /// Subclasses override to add validation (e.g. checking API key existence)
    /// but should call `super.loadModel(from:contextSize:)` or set the flag directly.
    open func loadModel(from url: URL, contextSize: Int32) async throws {
        guard withStateLock({ _baseURL }) != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:...) first."
            )
        }
        withStateLock { _isModelLoaded = true }
        Log.inference.info("\(self.backendName) backend loaded (model: \(self.modelName))")
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        guard withStateLock({ _isModelLoaded && _baseURL != nil }) else {
            throw CloudBackendError.invalidURL("Backend not configured. Call loadModel first.")
        }

        let request = try buildRequest(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )

        withStateLock {
            _isGenerating = true
            _lastUsage = nil
        }

        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: CloudBackendError.streamInterrupted)
                return
            }

            let session = self.urlSession

            let task = Task { [weak self] in
                defer { self?.withStateLock { self?._isGenerating = false } }

                do {
                    try await withExponentialBackoff {
                        let (bytes, response) = try await session.bytes(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw CloudBackendError.networkError(
                                underlying: URLError(.badServerResponse)
                            )
                        }

                        try await self?.checkStatusCode(httpResponse, bytes: bytes)

                        let tokenStream = SSEStreamParser.parse(bytes: bytes)
                        for try await payload in tokenStream {
                            if Task.isCancelled { break }

                            if let token = self?.extractToken(from: payload) {
                                continuation.yield(token)
                            }

                            if let usage = self?.extractUsage(from: payload) {
                                self?.handleUsage(usage)
                            }

                            if self?.isStreamEnd(payload) == true {
                                break
                            }

                            if let error = self?.extractStreamError(from: payload) {
                                throw error
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        Log.network.error("\(self?.backendName ?? "SSECloud") stream error: \(error.localizedDescription, privacy: .private)")
                        continuation.finish(throwing: error)
                    }
                }
            }

            self.withStateLock { self.currentTask = task }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Control

    public func stopGeneration() {
        withStateLock {
            currentTask?.cancel()
            currentTask = nil
            _isGenerating = false
        }
    }

    open func unloadModel() {
        stopGeneration()
        withStateLock {
            _baseURL = nil
            _keychainAccount = nil
            _ephemeralAPIKey = nil
            _isModelLoaded = false
        }
        Log.inference.info("\(self.backendName) backend unloaded")
    }

    // MARK: - HTTP Status Validation

    /// Checks the HTTP status code and throws an appropriate error for non-2xx responses.
    ///
    /// Handles 401/403 (auth), 429 (rate limit with Retry-After), and 5xx (server error
    /// with body extraction). Subclasses can override for provider-specific status handling.
    open func checkStatusCode(
        _ response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        let statusCode = response.statusCode
        guard !(200...299).contains(statusCode) else { return }

        switch statusCode {
        case 401, 403:
            throw CloudBackendError.authenticationFailed(provider: backendName)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CloudBackendError.rateLimited(retryAfter: retryAfter)
        default:
            var errorBody = ""
            for try await byte in bytes {
                errorBody.append(Character(UnicodeScalar(byte)))
                if errorBody.count > 2048 { break }
            }
            let message = extractErrorMessage(from: errorBody)
                ?? "Unexpected server error (status \(statusCode))"
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
    }

    /// Extracts an error message from a JSON error response body.
    ///
    /// The default implementation handles the common `{"error":{"message":"..."}}` format
    /// used by OpenAI and Anthropic. Subclasses can override for different formats.
    open func extractErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = parsed["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    // MARK: - State Mutation Helpers (for subclass use)

    /// Sets `isModelLoaded` under the state lock.
    public func setIsModelLoaded(_ value: Bool) {
        withStateLock { _isModelLoaded = value }
    }

    /// Sets `isGenerating` under the state lock.
    public func setIsGenerating(_ value: Bool) {
        withStateLock { _isGenerating = value }
    }
}

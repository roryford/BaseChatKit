import Foundation
import os
import BaseChatCore

/// Cloud inference backend for KoboldCpp servers.
///
/// KoboldCpp uses a flat prompt-based API rather than OpenAI's messages format.
/// The caller is responsible for formatting the prompt using a `PromptTemplate`
/// (``capabilities.requiresPromptTemplate`` is `true`).
///
/// Supports both streaming (SSE with `{"token":"..."}`) and non-streaming
/// (`{"results":[{"text":"..."}]}`) responses.
///
/// Usage:
/// ```swift
/// let backend = KoboldCppBackend()
/// backend.configure(
///     baseURL: URL(string: "http://localhost:5001")!,
///     modelName: "koboldcpp"
/// )
/// try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
/// let stream = try backend.generate(prompt: "### Instruction:\nHello\n### Response:\n", systemPrompt: nil, config: .init())
/// for try await token in stream { print(token, terminator: "") }
/// ```
public final class KoboldCppBackend: InferenceBackend, ConversationHistoryReceiver, @unchecked Sendable {

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
    private var modelName: String = "koboldcpp"

    /// Optional GBNF grammar constraint sent in the request body.
    /// KoboldCpp-specific — not part of the shared `GenerationConfig`.
    public var grammarConstraint: String?

    // MARK: - State

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    /// Full conversation history for multi-turn support.
    /// Set by InferenceService before each generate call.
    public var conversationHistory: [(role: String, content: String)]?

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        conversationHistory = messages
    }

    /// Context length reported by the KoboldCpp server, or 4096 as default.
    private var maxContextLength: Int32 = 4096

    public var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP, .topK, .typicalP, .repeatPenalty],
            maxContextTokens: maxContextLength,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external
        )
    }

    private var currentTask: Task<Void, Never>?
    private let urlSession: URLSession

    /// Shared session with certificate pinning delegate.
    private static let pinnedSession: URLSession = {
        let delegate = PinnedSessionDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    // MARK: - Init

    /// Creates a KoboldCpp backend.
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
    ///   - baseURL: The base URL of the KoboldCpp server (e.g. `http://localhost:5001`).
    ///              API paths are appended automatically.
    ///   - modelName: An optional label for the model. KoboldCpp serves whatever
    ///                model was loaded at startup, so this is purely informational.
    public func configure(baseURL: URL, modelName: String = "koboldcpp") {
        self.baseURL = baseURL
        self.modelName = modelName
    }

    // MARK: - InferenceBackend

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        guard let baseURL else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:modelName:) first."
            )
        }

        // Query the server's max context length for accurate capabilities reporting.
        await queryMaxContextLength(baseURL: baseURL)

        isModelLoaded = true
        Self.inferenceLogger.info("KoboldCpp backend configured for \(self.modelName, privacy: .public) at \(baseURL.host() ?? "unknown", privacy: .public) (ctx: \(self.maxContextLength))")
    }

    /// Queries GET /api/v1/config/max_context_length to learn the server's context size.
    /// Failures are non-fatal — falls back to the 4096 default.
    private func queryMaxContextLength(baseURL: URL) async {
        let configURL = baseURL.appendingPathComponent("api/v1/config/max_context_length")
        var request = URLRequest(url: configURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = json["value"] as? Int else {
                return
            }
            maxContextLength = Int32(value)
        } catch {
            Self.networkLogger.debug("Could not query KoboldCpp context length: \(error.localizedDescription, privacy: .private)")
        }
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
            config: config
        )

        isGenerating = true

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

                        // KoboldCpp streaming uses SSE with {"token":"..."} payloads.
                        let tokenStream = SSEStreamParser.parse(bytes: bytes)
                        for try await payload in tokenStream {
                            if Task.isCancelled { break }

                            if let token = Self.extractStreamingToken(from: payload) {
                                continuation.yield(token)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        Self.networkLogger.error("KoboldCpp stream error: \(error.localizedDescription, privacy: .private)")
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
        isModelLoaded = false
        maxContextLength = 4096
        Self.inferenceLogger.info("KoboldCpp backend unloaded")
    }

    // MARK: - Request Building

    private func buildRequest(
        baseURL: URL,
        prompt: String,
        config: GenerationConfig
    ) throws -> URLRequest {
        let generateURL = baseURL.appendingPathComponent("api/v1/generate")

        var body: [String: Any] = [
            "prompt": prompt,
            "max_length": config.maxOutputTokens ?? Int(config.maxTokens),
            "temperature": config.temperature,
            "top_p": config.topP,
            "top_k": config.topK.map { Int($0) } ?? 40,
            "typical": config.typicalP ?? 1.0,
            "rep_pen": config.repeatPenalty
        ]

        if let grammar = grammarConstraint {
            body["grammar"] = grammar
        }

        var request = URLRequest(url: generateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Self.networkLogger.debug("KoboldCpp request to \(generateURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

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
            let message = "Unexpected server error (status \(statusCode))"
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
    }

    // MARK: - SSE Payload Handler

    /// KoboldCpp-specific SSE payload interpreter.
    static let payloadHandler = KoboldCppPayloadHandler()

    struct KoboldCppPayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            KoboldCppBackend.extractStreamingToken(from: payload)
        }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            nil
        }
        func isStreamEnd(_ payload: String) -> Bool { false }
        func extractStreamError(from payload: String) -> Error? { nil }
    }

    // MARK: - JSON Parsing

    /// Extracts the token from a KoboldCpp streaming SSE payload.
    ///
    /// Expected format:
    /// ```json
    /// {"token":"word"}
    /// ```
    static func extractStreamingToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = parsed["token"] as? String else {
            return nil
        }
        return token
    }

    /// Extracts the generated text from a KoboldCpp non-streaming response.
    ///
    /// Expected format:
    /// ```json
    /// {"results":[{"text":"generated text"}]}
    /// ```
    static func extractNonStreamingText(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = parsed["results"] as? [[String: Any]],
              let first = results.first,
              let text = first["text"] as? String else {
            return nil
        }
        return text
    }
}

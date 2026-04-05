import Foundation
import os
import BaseChatCore

/// Inference backend for Ollama servers using the native `/api/chat` endpoint.
///
/// Ollama streams responses as newline-delimited JSON (NDJSON) rather than SSE,
/// so this backend parses each line directly instead of using `SSEStreamParser`.
///
/// Use ``OllamaModelListService`` to discover available models before configuring
/// this backend.
///
/// ## Bonjour Discovery
///
/// `BonjourDiscoveryService` scans for `_ollama._tcp` services on the LAN and
/// surfaces them as ``DiscoveredServer`` candidates. The consuming app must add
/// `NSLocalNetworkUsageDescription` to its `Info.plist` for Bonjour to work.
///
/// Usage:
/// ```swift
/// let backend = OllamaBackend()
/// backend.configure(baseURL: URL(string: "http://localhost:11434")!, modelName: "llama3.2")
/// try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await token in stream { print(token, terminator: "") }
/// ```
public final class OllamaBackend: InferenceBackend, ConversationHistoryReceiver, CloudBackendURLModelConfigurable, @unchecked Sendable {

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
    private var modelName: String = "llama3.2"

    // MARK: - State

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    public var conversationHistory: [(role: String, content: String)]?

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        conversationHistory = messages
    }

    public var capabilities: BackendCapabilities {
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
            isRemote: true
        )
    }

    private var currentTask: Task<Void, Never>?
    private let urlSession: URLSession

    /// Shared session with certificate pinning disabled for LAN use.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    // MARK: - Init

    /// Creates an Ollama backend.
    ///
    /// - Parameter urlSession: Custom URLSession for testing. Pass `nil` to use the default.
    public init(urlSession: URLSession? = nil) {
        self.urlSession = urlSession ?? Self.defaultSession
    }

    // MARK: - CloudBackendURLModelConfigurable

    /// Configures the backend. Call before ``loadModel(from:contextSize:)``.
    ///
    /// - Parameters:
    ///   - baseURL: Ollama server URL (e.g. `http://localhost:11434`).
    ///   - modelName: Model tag as returned by `/api/tags` (e.g. `"llama3.2:8b"`).
    public func configure(baseURL: URL, modelName: String = "llama3.2") {
        self.baseURL = baseURL
        self.modelName = modelName
    }

    // MARK: - InferenceBackend

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:modelName:) first."
            )
        }
        isModelLoaded = true
        Self.inferenceLogger.info("OllamaBackend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public)")
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

        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: CloudBackendError.streamInterrupted)
                return
            }

            let session = self.urlSession

            let task = Task { [weak self] in
                defer { self?.isGenerating = false }

                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw CloudBackendError.networkError(
                            underlying: URLError(.badServerResponse)
                        )
                    }

                    try await Self.checkStatusCode(httpResponse, bytes: bytes)

                    // Ollama streams NDJSON — each line is a complete JSON object.
                    var lineBuffer = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { break }

                        if byte == UInt8(ascii: "\n") {
                            if !lineBuffer.isEmpty {
                                if let line = String(data: lineBuffer, encoding: .utf8),
                                   let token = Self.extractToken(from: line) {
                                    continuation.yield(token)
                                }
                                lineBuffer.removeAll(keepingCapacity: true)
                            }
                        } else {
                            lineBuffer.append(byte)
                        }
                    }

                    // Flush any final line without a trailing newline.
                    if !lineBuffer.isEmpty,
                       let line = String(data: lineBuffer, encoding: .utf8),
                       let token = Self.extractToken(from: line) {
                        continuation.yield(token)
                    }

                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        Self.networkLogger.error("OllamaBackend stream error: \(error.localizedDescription, privacy: .private)")
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
        Self.inferenceLogger.info("OllamaBackend unloaded")
    }

    // MARK: - Request Building

    private func buildRequest(
        baseURL: URL,
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> URLRequest {
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

        let options: [String: Any] = [
            "temperature": config.temperature,
            "top_p": config.topP,
            "top_k": config.topK.map { Int($0) } ?? 40,
            "repeat_penalty": config.repeatPenalty,
            "num_predict": config.maxOutputTokens ?? Int(config.maxTokens),
        ]

        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "options": options,
        ]

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Self.networkLogger.debug("OllamaBackend request to \(chatURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - Response Handling

    private static func checkStatusCode(
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
            var errorBody = ""
            for try await byte in bytes {
                errorBody.append(Character(UnicodeScalar(byte)))
                if errorBody.count > 2048 { break }
            }
            let message = extractErrorMessage(from: errorBody) ?? "Unexpected server error (status \(statusCode))"
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
    }

    // MARK: - NDJSON Parsing

    /// Extracts the assistant content token from an Ollama `/api/chat` NDJSON line.
    ///
    /// Ollama streaming format (one JSON object per line, no `data:` prefix):
    /// ```json
    /// {"model":"llama3","message":{"role":"assistant","content":"Hello"},"done":false}
    /// ```
    /// Final chunk has `"done":true` and empty or absent content — we skip it.
    static func extractToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Skip the final "done" chunk.
        if let done = parsed["done"] as? Bool, done { return nil }

        guard let message = parsed["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            return nil
        }

        return content
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
}

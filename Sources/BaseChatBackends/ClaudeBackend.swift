import Foundation
import os
import BaseChatCore

/// Anthropic Claude API inference backend.
///
/// Streams completions from the Anthropic Messages API (`/v1/messages`).
/// Handles Claude-specific SSE event types (`content_block_delta`, etc.)
/// and authentication via `x-api-key` header.
public final class ClaudeBackend: InferenceBackend {

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
    private var apiKey: String?
    private var modelName: String = "claude-sonnet-4-20250514"

    /// Token usage from the most recent generation, if available.
    public private(set) var lastUsage: (promptTokens: Int, completionTokens: Int)?

    // MARK: - Private

    private var currentTask: Task<Void, Never>?
    private let urlSession: URLSession

    // MARK: - Init

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Configuration

    /// Configures the backend with connection details.
    ///
    /// Call this before `loadModel(from:contextSize:)`.
    /// - Parameters:
    ///   - baseURL: Anthropic API base URL (e.g. `https://api.anthropic.com`).
    ///   - apiKey: Anthropic API key (`sk-ant-...`).
    ///   - modelName: Model identifier (e.g. `claude-sonnet-4-20250514`).
    public func configure(baseURL: URL, apiKey: String?, modelName: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw CloudBackendError.missingAPIKey
        }
        isModelLoaded = true
        Self.inferenceLogger.info("Claude backend loaded (model: \(self.modelName))")
    }

    public func unloadModel() {
        stopGeneration()
        baseURL = nil
        apiKey = nil
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
        guard let apiKey, !apiKey.isEmpty else {
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
                            self?.lastUsage = (
                                promptTokens: usage.promptTokens ?? self?.lastUsage?.promptTokens ?? 0,
                                completionTokens: usage.completionTokens ?? self?.lastUsage?.completionTokens ?? 0
                            )
                        }

                        if Self.isStreamEnd(payload) {
                            break
                        }

                        if let error = Self.extractStreamError(from: payload) {
                            throw error
                        }
                    }

                    continuation.finish()

                } catch {
                    if !Task.isCancelled {
                        Self.networkLogger.error("Claude stream error: \(error)")
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
            "max_tokens": Int(config.maxTokens),
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

    // MARK: - SSE Payload Parsing

    /// Extracts a text token from a `content_block_delta` event payload.
    private static func extractToken(from json: String) -> String? {
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

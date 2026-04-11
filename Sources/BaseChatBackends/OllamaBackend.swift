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
/// try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await event in stream.events { if case .token(let t) = event { print(t, terminator: "") } }
/// ```
public final class OllamaBackend: SSECloudBackend, CloudBackendURLModelConfigurable, @unchecked Sendable {

    /// How long Ollama should keep the model loaded in VRAM after a request.
    /// Default is "30m" (30 minutes). Ollama's own default is "5m".
    public var keepAlive: String = "30m"

    // MARK: - Init

    /// Creates an Ollama backend.
    ///
    /// - Parameter urlSession: Custom URLSession for testing. Pass `nil` to use the default.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "llama3.2",
            urlSession: urlSession ?? URLSessionProvider.unpinned
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
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 128_000,
            supportsStreaming: true,
            isRemote: true
        )
    }

    // MARK: - Model Lifecycle

    public override func loadModel(from url: URL, contextSize: Int32) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:modelName:) first."
            )
        }
        setIsModelLoaded(true)
        Log.inference.info("OllamaBackend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public)")
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
            "keep_alive": keepAlive,
        ]

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
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        var lineBuffer = Data()
        for try await byte in bytes {
            if Task.isCancelled { break }

            if byte == UInt8(ascii: "\n") {
                if !lineBuffer.isEmpty {
                    if let line = String(data: lineBuffer, encoding: .utf8),
                       let token = Self.extractToken(from: line) {
                        continuation.yield(.token(token))
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
            continuation.yield(.token(token))
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
            let message = Self.extractErrorMessage(from: errorBody) ?? "Unexpected server error (status \(statusCode))"
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
    }

    // MARK: - SSE Hooks (unused for NDJSON, but required by base class)

    public override func extractToken(from payload: String) -> String? {
        Self.extractToken(from: payload)
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

    // MARK: - Unload

    public override func unloadModel() {
        super.unloadModel()
    }
}

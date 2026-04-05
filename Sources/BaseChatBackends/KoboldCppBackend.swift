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
public final class KoboldCppBackend: SSECloudBackend, CloudBackendURLModelConfigurable, @unchecked Sendable {

    /// Optional GBNF grammar constraint sent in the request body.
    /// KoboldCpp-specific — not part of the shared `GenerationConfig`.
    public var grammarConstraint: String?

    /// Context length reported by the KoboldCpp server, or 4096 as default.
    private var maxContextLength: Int32 = 4096

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
        super.init(
            defaultModelName: "koboldcpp",
            urlSession: urlSession ?? Self.pinnedSession
        )
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "KoboldCpp" }

    public override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP, .topK, .typicalP, .repeatPenalty],
            maxContextTokens: maxContextLength,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 4096,
            supportsStreaming: true,
            isRemote: true
        )
    }

    // MARK: - Configuration

    /// Configures the backend with connection details. Call before ``loadModel(from:contextSize:)``.
    ///
    /// - Parameter baseURL: The base URL of the KoboldCpp server (e.g. `http://localhost:5001`).
    ///                      API paths are appended automatically.
    public func configure(baseURL: URL) {
        super.configure(baseURL: baseURL, modelName: "koboldcpp")
    }

    // MARK: - Model Lifecycle

    public override func loadModel(from url: URL, contextSize: Int32) async throws {
        guard let baseURL else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:modelName:) first."
            )
        }

        // Query the server's max context length for accurate capabilities reporting.
        await queryMaxContextLength(baseURL: baseURL)

        setIsModelLoaded(true)
        Log.inference.info("KoboldCpp backend configured for \(self.modelName, privacy: .public) at \(baseURL.host() ?? "unknown", privacy: .public) (ctx: \(self.maxContextLength))")
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
            Log.network.debug("Could not query KoboldCpp context length: \(error.localizedDescription, privacy: .private)")
        }
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

        Log.network.debug("KoboldCpp request to \(generateURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - SSE Payload Handling

    public override func extractToken(from payload: String) -> String? {
        Self.extractStreamingToken(from: payload)
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

    // MARK: - Unload

    public override func unloadModel() {
        super.unloadModel()
        maxContextLength = 4096
    }
}

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
/// for try await event in stream.events { if case .token(let t) = event { print(t, terminator: "") } }
/// ```
public final class OpenAIBackend: SSECloudBackend, TokenUsageProvider, CloudBackendURLModelConfigurable, CloudBackendKeychainConfigurable, ToolCallingBackend, @unchecked Sendable {

    // MARK: - Tool Calling State

    private var _toolDefinitions: [ToolDefinition] = []
    private var _toolProvider: (any ToolProvider)?
    private var _toolCallObserver: (any ToolCallObserver)?

    public var toolCallObserver: (any ToolCallObserver)? {
        get { withStateLock { _toolCallObserver } }
        set { withStateLock { _toolCallObserver = newValue } }
    }

    public func setTools(_ tools: [ToolDefinition]) {
        withStateLock { _toolDefinitions = tools }
    }

    public func setToolProvider(_ provider: (any ToolProvider)?) {
        withStateLock { _toolProvider = provider }
    }

    // MARK: - Init

    /// Creates an OpenAI-compatible backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "gpt-4o-mini",
            urlSession: urlSession ?? URLSessionProvider.pinned
        )
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "OpenAI" }

    public override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 128_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 16_384,
            supportsStreaming: true,
            isRemote: true
        )
    }

    // MARK: - Model Lifecycle

    public override func loadModel(from url: URL, contextSize: Int32) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:apiKey:modelName:) first."
            )
        }
        setIsModelLoaded(true)
        Log.inference.info("OpenAI backend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public)")
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

        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": config.temperature,
            "top_p": config.topP,
            "max_tokens": config.maxOutputTokens ?? Int(config.maxTokens)
        ]

        // Include tool definitions when available
        let toolDefs = withStateLock { _toolDefinitions }
        if !toolDefs.isEmpty {
            body["tools"] = toolDefs.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": [
                            "type": tool.inputSchema.type,
                            "properties": Dictionary(uniqueKeysWithValues: tool.inputSchema.properties.map { key, prop in
                                var propDict: [String: Any] = [
                                    "type": prop.type,
                                    "description": prop.description
                                ]
                                if let enumValues = prop.enumValues {
                                    propDict["enum"] = enumValues
                                }
                                return (key, propDict)
                            }),
                            "required": tool.inputSchema.required
                        ] as [String: Any]
                    ] as [String: Any]
                ]
            }
        }

        var request = URLRequest(url: completionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = resolveAPIKey(), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.network.debug("OpenAI request to \(completionsURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - SSE Payload Handling

    public override func extractToken(from payload: String) -> String? {
        Self.parseToken(from: payload)
    }

    public override func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let usage = Self.parseUsage(from: payload) else { return nil }
        return (promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
    }

    // MARK: - SSE Payload Handler

    /// OpenAI-specific SSE payload interpreter for use with `SSEStreamParser.streamTokens`.
    static let payloadHandler = OpenAIPayloadHandler()

    struct OpenAIPayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            OpenAIBackend.parseToken(from: payload)
        }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            guard let usage = OpenAIBackend.parseUsage(from: payload) else { return nil }
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
    private static func parseToken(from json: String) -> String? {
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
    private static func parseUsage(from json: String) -> (promptTokens: Int, completionTokens: Int)? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = parsed["usage"] as? [String: Any],
              let prompt = usage["prompt_tokens"] as? Int,
              let completion = usage["completion_tokens"] as? Int else {
            return nil
        }
        return (prompt, completion)
    }

    /// Extracts tool call information from an OpenAI streaming delta.
    ///
    /// OpenAI streams tool calls via `delta.tool_calls` in the choices array:
    /// ```json
    /// {"choices":[{"delta":{"tool_calls":[{"id":"call_123","function":{"name":"get_weather","arguments":"{...}"}}]}}]}
    /// ```
    static func parseToolCalls(from json: String) -> [ToolCall]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let toolCalls = delta["tool_calls"] as? [[String: Any]] else {
            return nil
        }

        return toolCalls.compactMap { call -> ToolCall? in
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else {
                return nil
            }
            let arguments = function["arguments"] as? String ?? "{}"
            return ToolCall(id: id, name: name, arguments: arguments)
        }
    }
}

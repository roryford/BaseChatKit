#if CloudSaaS
import Foundation
import os
import BaseChatInference

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
/// try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await event in stream.events { if case .token(let t) = event { print(t, terminator: "") } }
/// ```
public final class OpenAIBackend: SSECloudBackend, TokenUsageProvider, CloudBackendURLModelConfigurable, CloudBackendKeychainConfigurable, @unchecked Sendable {

    // MARK: - Init

    /// Creates an OpenAI-compatible backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    ///
    /// When `urlSession` is `nil` and the runtime kill-switch
    /// ``URLSessionProvider/networkDisabled`` is set, the underlying property
    /// access traps. Use ``makeChecked(urlSession:)`` for a throwing variant
    /// that surfaces the kill-switch as a recoverable error.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "gpt-4o-mini",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            payloadHandler: OpenAIPayloadHandler()
        )
    }

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    public static func makeChecked(urlSession: URLSession? = nil) throws -> OpenAIBackend {
        let session: URLSession
        if let urlSession {
            session = urlSession
        } else {
            session = try URLSessionProvider.throwingPinned()
        }
        return OpenAIBackend(urlSession: session)
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "OpenAI" }

    public override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 128_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 16_384,
            supportsStreaming: true,
            isRemote: true
        )
    }

    // MARK: - Model Lifecycle

    // Plan is informational for cloud backends.
    public override func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
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
            "max_tokens": config.maxOutputTokens ?? 2048
        ]
        if config.jsonMode {
            body["response_format"] = ["type": "json_object"]
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

    // MARK: - Stream Parsing

    /// Parses OpenAI Chat Completions SSE with reasoning-model support.
    ///
    /// OpenAI-compatible reasoning models (o1/o3, DeepSeek R1, xAI Grok
    /// reasoning, hosted Qwen reasoning) expose chain-of-thought text alongside
    /// visible content via one of two Chat Completions delta shapes:
    ///
    /// ```json
    /// {"choices":[{"delta":{"reasoning_content":"..."}}]}   // DeepSeek / compat
    /// {"choices":[{"delta":{"reasoning":"..."}}]}           // OpenAI-native
    /// ```
    ///
    /// We route reasoning fragments to ``GenerationEvent/thinkingToken(_:)``
    /// and emit a single ``GenerationEvent/thinkingComplete`` on the first
    /// transition from reasoning to visible `content` (or on stream end if
    /// reasoning never handed off to content — truncated upstream). Streams
    /// from non-reasoning models (plain gpt-4o-mini, etc.) never observe a
    /// reasoning chunk and therefore never fire `.thinkingComplete`.
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let tokenStream = SSEStreamParser.parse(bytes: bytes, limits: effectiveSSEStreamLimits)

        var thinkingOpen = false

        func flushThinkingCompleteIfNeeded() {
            if thinkingOpen {
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
            }
        }

        for try await payload in tokenStream {
            if Task.isCancelled { break }

            // Reasoning delta: emit as thinkingToken, keep the block open.
            if let thinking = Self.parseReasoningDelta(from: payload) {
                continuation.yield(.thinkingToken(thinking))
                thinkingOpen = true
                // Fall through — a single chunk may legally carry both
                // reasoning and content (edge case on some providers), and
                // usage may still need emitting.
            }

            // Visible content delta: close thinking first so consumers see a
            // clean handoff before the first visible token.
            if let token = extractToken(from: payload) {
                flushThinkingCompleteIfNeeded()
                continuation.yield(.token(token))
            }

            if let usage = extractUsage(from: payload) {
                handleUsage(usage)
                if let prompt = usage.promptTokens,
                   let completion = usage.completionTokens {
                    continuation.yield(.usage(prompt: prompt, completion: completion))
                }
            }

            if isStreamEnd(payload) {
                flushThinkingCompleteIfNeeded()
                break
            }

            if let error = extractStreamError(from: payload) {
                throw error
            }
        }

        flushThinkingCompleteIfNeeded()
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

    /// Extracts reasoning text from an OpenAI-compatible Chat Completions delta.
    ///
    /// Two shapes are recognised:
    /// ```json
    /// {"choices":[{"delta":{"reasoning_content":"..."}}]}
    /// {"choices":[{"delta":{"reasoning":"..."}}]}
    /// ```
    /// The `reasoning_content` field is used by DeepSeek R1 and by OpenAI-
    /// compatible hosts that mirror DeepSeek's convention; `reasoning` is used
    /// by some newer OpenAI-hosted reasoning deployments. Anything else —
    /// including plain `content` — returns `nil` so the caller can fall back
    /// to the standard token extractor.
    static func parseReasoningDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any] else {
            return nil
        }
        if let content = delta["reasoning_content"] as? String, !content.isEmpty {
            return content
        }
        if let content = delta["reasoning"] as? String, !content.isEmpty {
            return content
        }
        return nil
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

}
#endif


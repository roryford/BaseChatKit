import Testing
import Foundation
@testable import BaseChatBackends
@testable import BaseChatCore
import BaseChatTestSupport

// MARK: - Helpers

/// Creates a `URLSession` whose traffic is intercepted by `MockURLProtocol`.
private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Formats a single SSE data line from a JSON string.
private func sseData(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
}

/// Formats the SSE `[DONE]` sentinel.
private let sseDone = Data("data: [DONE]\n\n".utf8)

/// Creates an OpenAIBackend configured for a unique test URL.
///
/// Each call uses a UUID-based hostname, so stubs from different tests
/// never collide. We do NOT call `MockURLProtocol.reset()` here because
/// that clears ALL global stubs and would corrupt concurrent test suites
/// (e.g. CloudBackendSSETests) that also use MockURLProtocol.
private func makeOllamaBackend() -> (OpenAIBackend, URL) {
    let session = makeMockSession()
    let backend = OpenAIBackend(urlSession: session)
    let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
    backend.configure(baseURL: baseURL, apiKey: nil, modelName: "llama3")
    return (backend, baseURL.appendingPathComponent("v1/chat/completions"))
}

private func makeKoboldCppBackend() -> (OpenAIBackend, URL) {
    let session = makeMockSession()
    let backend = OpenAIBackend(urlSession: session)
    let baseURL = URL(string: "http://koboldcpp-\(UUID().uuidString).test")!
    backend.configure(baseURL: baseURL, apiKey: nil, modelName: "koboldcpp")
    return (backend, baseURL.appendingPathComponent("v1/chat/completions"))
}

private func makeCompatBackend(modelName: String) -> (OpenAIBackend, URL) {
    let session = makeMockSession()
    let backend = OpenAIBackend(urlSession: session)
    let baseURL = URL(string: "http://compat-\(UUID().uuidString).test")!
    backend.configure(baseURL: baseURL, apiKey: nil, modelName: modelName)
    return (backend, baseURL.appendingPathComponent("v1/chat/completions"))
}

private func loadBackend(_ backend: OpenAIBackend) async throws {
    try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
}

/// Extracts the HTTP body from a captured request, handling both httpBody and httpBodyStream.
private func extractBody(from request: URLRequest?) throws -> Data {
    guard let request else {
        Issue.record("No captured request")
        return Data()
    }
    if let body = request.httpBody { return body }
    if let stream = request.httpBodyStream {
        var data = Data()
        stream.open()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read > 0 { data.append(buffer, count: read) }
        }
        stream.close()
        return data
    }
    Issue.record("Request has neither httpBody nor httpBodyStream")
    return Data()
}

// MARK: - OpenAI-Compatible Endpoint Tests
//
// All E2E tests that use MockURLProtocol must run serialized to avoid
// cross-test stub interference (MockURLProtocol uses global shared state).

@Suite("OpenAI-compat endpoints (Ollama + KoboldCpp)", .serialized)
struct OpenAICompatEndpointTests {

    // =========================================================================
    // MARK: - Ollama Streaming
    // =========================================================================

    @Test func ollama_streaming_standardChunks() async throws {
        let (backend, url) = makeOllamaBackend()

        // Ollama's streaming format mirrors OpenAI's but includes an "ollama"
        // system_fingerprint and may omit some fields OpenAI includes.
        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":"Once"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":" upon"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":" a time"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Tell me a story",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        // Empty first chunk (role-only) yields empty string; content chunks follow.
        let meaningful = tokens.filter { !$0.isEmpty }
        #expect(meaningful == ["Once", " upon", " a time"])
    }

    @Test func ollama_streaming_withUsage() async throws {
        let (backend, url) = makeOllamaBackend()

        // Ollama supports stream_options.include_usage (added in 0.4.0).
        // Usage arrives in the final chunk, same as OpenAI.
        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-456","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-456","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":15,"completion_tokens":1,"total_tokens":16}}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        for try await _ in stream.events { }

        // Verify token usage was extracted
        let usage = backend.lastUsage
        #expect(usage?.promptTokens == 15)
        #expect(usage?.completionTokens == 1)
    }

    /// Ollama versions before 0.4.0 do not support `stream_options` and silently
    /// ignore it. The final chunk has no `usage` field. OpenAIBackend should handle
    /// this gracefully (lastUsage stays nil).
    @Test func ollama_streaming_withoutUsageSupport() async throws {
        let (backend, url) = makeOllamaBackend()

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-789","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-789","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        #expect(tokens == ["Hello"])
        // No usage data when Ollama doesn't support stream_options
        #expect(backend.lastUsage == nil)
    }

    // =========================================================================
    // MARK: - Ollama Errors
    // =========================================================================

    /// Ollama may return an error as a JSON body with a non-200 status,
    /// using OpenAI-compatible error format.
    @Test func ollama_error_modelNotFound() async throws {
        let (backend, url) = makeOllamaBackend()

        let body = Data("""
        {"error":{"message":"model 'nonexistent' not found, try pulling it first","type":"not_found","code":"model_not_found"}}
        """.utf8)

        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 404))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(
                prompt: "Hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await _ in stream.events {}
            Issue.record("Expected server error for missing model")
        } catch let error as CloudBackendError {
            switch error {
            case .serverError(let statusCode, let message):
                #expect(statusCode == 404)
                #expect(message.contains("not found"))
            default:
                Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - Ollama Auth
    // =========================================================================

    /// Ollama does not require an API key. Verify that OpenAIBackend works
    /// without authentication headers.
    @Test func ollama_noAuth_omitsAuthHeader() async throws {
        let (backend, url) = makeOllamaBackend()

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "test",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        // Verify no Authorization header was sent (apiKey was nil)
        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        #expect(captured != nil)
        let authHeader = captured?.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader == nil, "Ollama doesn't need auth -- no Authorization header should be sent")
    }

    // =========================================================================
    // MARK: - KoboldCpp Streaming
    // =========================================================================

    @Test func koboldCpp_streaming_standardChunks() async throws {
        let (backend, url) = makeKoboldCppBackend()

        // KoboldCpp's OpenAI-compatible streaming format. KoboldCpp may use
        // "koboldcpp" as the model name and may omit system_fingerprint.
        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-kobold-1","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-kobold-1","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":"The"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-kobold-1","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":" dragon"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-kobold-1","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":" roared"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-kobold-1","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Tell me a story",
            systemPrompt: "You are a storyteller.",
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        let meaningful = tokens.filter { !$0.isEmpty }
        #expect(meaningful == ["The", " dragon", " roared"])
    }

    /// KoboldCpp may send `finish_reason: "length"` when hitting max_length,
    /// which differs from OpenAI's `"stop"`. The token extraction should still work.
    @Test func koboldCpp_streaming_finishReasonLength() async throws {
        let (backend, url) = makeKoboldCppBackend()

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-kobold-2","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":"truncated output"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-kobold-2","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Write a very long story",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        #expect(tokens == ["truncated output"])
    }

    /// KoboldCpp does not support `stream_options.include_usage`.
    /// It silently ignores the parameter and never sends usage data.
    /// OpenAIBackend should handle this gracefully.
    ///
    /// INCOMPATIBILITY DOCUMENTED: KoboldCpp's OpenAI-compatible endpoint
    /// ignores `stream_options` entirely. `lastUsage` will always be nil
    /// when connecting to KoboldCpp via OpenAIBackend.
    @Test func koboldCpp_streaming_noUsageSupport() async throws {
        let (backend, url) = makeKoboldCppBackend()

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-kobold-3","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-kobold-3","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "test",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        for try await _ in stream.events { }

        // KoboldCpp never sends usage -- verify OpenAIBackend handles this.
        #expect(backend.lastUsage == nil)
    }

    // =========================================================================
    // MARK: - KoboldCpp Errors
    // =========================================================================

    /// KoboldCpp may return errors in a non-standard format. The `error`
    /// field may be a plain string instead of the OpenAI `{"error":{"message":...}}`
    /// nested object.
    ///
    /// INCOMPATIBILITY DOCUMENTED: When KoboldCpp returns errors in its native
    /// format (plain string `error` field), OpenAIBackend.extractErrorMessage
    /// will fail to parse it because it expects `{"error":{"message":"..."}}`.
    /// The fallback message "Unexpected server error (status N)" is used instead.
    @Test func koboldCpp_error_nativeErrorFormat() async throws {
        let (backend, url) = makeKoboldCppBackend()

        // KoboldCpp sometimes returns errors as `{"error": "message string"}`
        // instead of `{"error": {"message": "...", "type": "..."}}`
        let body = Data("""
        {"error":"No model loaded. Please load a model first."}
        """.utf8)

        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 503))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(
                prompt: "Hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch let error as CloudBackendError {
            switch error {
            case .serverError(let statusCode, let message):
                #expect(statusCode == 503)
                // KoboldCpp's flat error format is not parsed by extractErrorMessage,
                // so we get the fallback message. This is a known incompatibility.
                #expect(message.contains("503") || message.contains("No model loaded"),
                        "Error message should either be parsed or contain status code fallback")
            default:
                Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - KoboldCpp Auth
    // =========================================================================

    /// KoboldCpp does not require authentication.
    @Test func koboldCpp_noAuth_omitsAuthHeader() async throws {
        let (backend, url) = makeKoboldCppBackend()

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-kobold-4","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "test",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        #expect(captured != nil)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == nil,
                "KoboldCpp doesn't require auth -- no header should be present")
    }

    // =========================================================================
    // MARK: - Request Format Compatibility
    // =========================================================================

    /// Verifies the request body contains the expected fields for an
    /// OpenAI-compatible endpoint. Both Ollama and KoboldCpp accept this format.
    @Test func requestFormat_containsExpectedFields() async throws {
        let (backend, url) = makeCompatBackend(modelName: "test-model")

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"test-model","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: "You are helpful.",
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // Required fields that both Ollama and KoboldCpp expect
        #expect(json["model"] as? String == "test-model")
        #expect(json["stream"] as? Bool == true)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count >= 2, "Should have system + user messages")
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are helpful.")

        // temperature and top_p should be present
        #expect(json["temperature"] != nil)
        #expect(json["top_p"] != nil)

        // max_tokens should be present
        #expect(json["max_tokens"] != nil)
    }

    /// INCOMPATIBILITY DOCUMENTED: OpenAIBackend sends `stream_options`
    /// which is specific to OpenAI's API. KoboldCpp ignores this field
    /// silently, and Ollama only supports it from version 0.4.0+.
    /// Older Ollama versions ignore it. Neither server errors on it.
    @Test func requestFormat_containsStreamOptions() async throws {
        let (backend, url) = makeCompatBackend(modelName: "test-model")

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"test-model","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // stream_options is sent by OpenAIBackend -- harmless for KoboldCpp/Ollama
        // (they silently ignore unknown fields), but worth documenting.
        let streamOptions = json["stream_options"] as? [String: Any]
        #expect(streamOptions != nil, "stream_options is always sent (harmlessly ignored by KoboldCpp/old Ollama)")
        #expect(streamOptions?["include_usage"] as? Bool == true)
    }

    /// Verifies that conversation history is included in the request body,
    /// which is essential for multi-turn conversations with Ollama/KoboldCpp.
    @Test func requestFormat_includesConversationHistory() async throws {
        let (backend, url) = makeCompatBackend(modelName: "llama3")

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"6"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)

        backend.setConversationHistory([
            (role: "user", content: "What is 2+2?"),
            (role: "assistant", content: "4"),
            (role: "user", content: "And 3+3?"),
        ])

        let stream = try backend.generate(
            prompt: "And 3+3?",
            systemPrompt: "You are a calculator.",
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        // System prompt + 3 conversation history messages
        #expect(messages.count == 4)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "What is 2+2?")
        #expect(messages[2]["role"] as? String == "assistant")
        #expect(messages[3]["role"] as? String == "user")
    }
}

// MARK: - Payload Handler Unit Tests (no MockURLProtocol needed)

/// Tests edge cases in SSE payload parsing that may differ between providers.
/// These use the payload handler directly (unit-level) and do not need serialization.
@Suite("Provider SSE payload parsing")
struct ProviderSSEPayloadTests {

    // MARK: - Ollama Payload Format

    @Test func ollama_payloadHandler_extractsToken() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}
        """
        #expect(handler.extractToken(from: chunk) == "hello")
    }

    @Test func ollama_payloadHandler_finishChunkReturnsNil() {
        let handler = OpenAIBackend.payloadHandler

        let finishChunk = """
        {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """
        #expect(handler.extractToken(from: finishChunk) == nil)
    }

    @Test func ollama_payloadHandler_extractsUsage() {
        let handler = OpenAIBackend.payloadHandler

        let usageChunk = """
        {"id":"chatcmpl-456","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":50,"total_tokens":70}}
        """
        let usage = handler.extractUsage(from: usageChunk)
        #expect(usage?.promptTokens == 20)
        #expect(usage?.completionTokens == 50)
    }

    /// Ollama may include extra fields in the delta that OpenAI doesn't send.
    @Test func ollama_extraFieldsInDelta_parsesCorrectly() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"hello","extra_field":true},"finish_reason":null}],"done":false}
        """
        #expect(handler.extractToken(from: chunk) == "hello")
    }

    /// Ollama may send empty string content in early chunks.
    @Test func ollama_emptyContent_yieldsEmptyString() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
        """
        // extractToken returns "" (empty string) which is technically a valid return,
        // not nil. The caller should filter empty tokens if needed.
        let token = handler.extractToken(from: chunk)
        #expect(token == "")
    }

    // MARK: - KoboldCpp Payload Format

    @Test func koboldCpp_payloadHandler_extractsToken() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-kobold-1","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}
        """
        #expect(handler.extractToken(from: chunk) == "hello")
    }

    /// KoboldCpp may return `null` instead of omitting `finish_reason`.
    @Test func koboldCpp_nullFinishReason_parsesCorrectly() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-kobold-1","object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":"token"},"finish_reason":null}]}
        """
        #expect(handler.extractToken(from: chunk) == "token")
    }

    /// KoboldCpp may not include the `id` field in streaming chunks.
    /// OpenAIBackend should not depend on this field for token extraction.
    @Test func koboldCpp_missingId_parsesCorrectly() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"object":"chat.completion.chunk","created":1700000000,"model":"koboldcpp","choices":[{"index":0,"delta":{"content":"works"},"finish_reason":null}]}
        """
        #expect(handler.extractToken(from: chunk) == "works")
    }

    /// KoboldCpp may not include the `object` field.
    @Test func koboldCpp_missingObject_parsesCorrectly() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-kobold-1","model":"koboldcpp","choices":[{"index":0,"delta":{"content":"fine"}}]}
        """
        #expect(handler.extractToken(from: chunk) == "fine")
    }

    // MARK: - Unicode (both providers)

    /// Both Ollama and KoboldCpp may stream Unicode content.
    @Test func unicode_parsedCorrectly() {
        let handler = OpenAIBackend.payloadHandler

        let emojiChunk = """
        {"choices":[{"delta":{"content":"Hello \\ud83d\\ude00"}}]}
        """
        #expect(handler.extractToken(from: emojiChunk) == "Hello \u{1F600}")

        let cjkChunk = """
        {"choices":[{"delta":{"content":"\\u4f60\\u597d"}}]}
        """
        #expect(handler.extractToken(from: cjkChunk) == "\u{4F60}\u{597D}")

        let accentChunk = """
        {"choices":[{"delta":{"content":"caf\\u00e9"}}]}
        """
        #expect(handler.extractToken(from: accentChunk) == "caf\u{00E9}")
    }

    // MARK: - Malformed Responses

    /// Both providers may occasionally send malformed SSE payloads.
    @Test func malformedJSON_returnsNil() {
        let handler = OpenAIBackend.payloadHandler

        #expect(handler.extractToken(from: "not json at all") == nil)
        #expect(handler.extractToken(from: "{invalid") == nil)
        #expect(handler.extractToken(from: "") == nil)
        #expect(handler.extractToken(from: "{}") == nil)
        #expect(handler.extractToken(from: "{\"choices\":[]}") == nil)

        // Usage extraction should also be nil for malformed data
        #expect(handler.extractUsage(from: "not json") == nil)
        #expect(handler.extractUsage(from: "") == nil)
    }
}

// MARK: - Documented Incompatibilities
//
// The following incompatibilities were found between OpenAIBackend and
// KoboldCpp/Ollama's OpenAI-compatible endpoints. These are NOT bugs to fix
// in OpenAIBackend -- they are inherent differences in the providers.
//
// 1. `stream_options` parameter:
//    - OpenAIBackend always sends `"stream_options": {"include_usage": true}`
//    - KoboldCpp ignores this entirely (no usage data ever returned)
//    - Ollama < 0.4.0 ignores this; Ollama >= 0.4.0 supports it
//    - Impact: `lastUsage` will be nil when using KoboldCpp, and when using
//      older Ollama versions. Not a functional problem, just missing telemetry.
//    - Both servers silently ignore unknown fields, so this causes no errors.
//
// 2. Error response format:
//    - OpenAI: `{"error": {"message": "...", "type": "...", "code": "..."}}`
//    - Ollama:  `{"error": {"message": "...", "type": "...", "code": "..."}}` (compatible)
//    - KoboldCpp: sometimes `{"error": "plain string message"}` (flat format)
//    - Impact: When KoboldCpp returns flat-format errors, `extractErrorMessage`
//      returns nil and the fallback "Unexpected server error (status N)" is used.
//      The error is still caught -- the message is just less descriptive.
//
// 3. Model listing (`/v1/models`):
//    - Not tested here because OpenAIBackend does not call `/v1/models`.
//    - Model selection is done at configuration time, not via discovery.
//    - Ollama: `GET /v1/models` returns `{"object":"list","data":[...]}`
//    - KoboldCpp: `GET /v1/models` returns similar format but with a single entry
//    - If model discovery is added to OpenAIBackend in the future, both
//      formats should be tested.
//
// 4. Supported generation parameters:
//    - OpenAIBackend sends `temperature`, `top_p`, `max_tokens`
//    - Both Ollama and KoboldCpp accept these standard parameters
//    - KoboldCpp also accepts `top_k`, `typical_p`, `rep_pen` via its native
//      API, but these are NOT available through its OpenAI-compatible endpoint.
//      Use the dedicated KoboldCppBackend for those parameters.
//    - Ollama supports additional `options` field in its native API for
//      `num_ctx`, `top_k`, `repeat_penalty`, etc. -- not available via
//      OpenAI-compatible endpoint.
//
// 5. Authentication:
//    - Neither KoboldCpp nor Ollama require API keys by default.
//    - OpenAIBackend correctly omits the Authorization header when apiKey is nil.
//    - No incompatibility here -- just worth noting for documentation.

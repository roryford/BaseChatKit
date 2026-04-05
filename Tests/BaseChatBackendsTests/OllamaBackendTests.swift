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

/// Formats a single Ollama NDJSON line.
private func ndjsonLine(_ json: String) -> Data {
    Data("\(json)\n".utf8)
}

// MARK: - OllamaBackend Tests

@Suite("OllamaBackend", .serialized)
struct OllamaBackendTests {

    // MARK: - Setup helpers

    private func makeConfiguredBackend() -> (OllamaBackend, URL) {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.2")
        return (backend, baseURL.appendingPathComponent("api/chat"))
    }

    private func loadBackend(_ backend: OllamaBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
    }

    // MARK: - Init & State

    @Test func init_defaultState() {
        let backend = OllamaBackend()
        #expect(!backend.isModelLoaded)
        #expect(!backend.isGenerating)
    }

    @Test func loadModel_withoutConfigure_throws() async {
        let backend = OllamaBackend()
        do {
            try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
            Issue.record("Expected throw when no base URL configured")
        } catch {
            // expected
        }
    }

    @Test func configure_thenLoad_succeeds() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        #expect(backend.isModelLoaded)
    }

    @Test func unloadModel_clearsState() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        backend.unloadModel()
        #expect(!backend.isModelLoaded)
        #expect(!backend.isGenerating)
    }

    @Test func generate_withoutLoad_throws() {
        let backend = OllamaBackend()
        #expect(throws: (any Error).self) {
            try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        }
    }

    // MARK: - Capabilities

    @Test func capabilities_supportsExpectedParameters() {
        let caps = OllamaBackend().capabilities
        #expect(caps.supportedParameters.contains(.temperature))
        #expect(caps.supportedParameters.contains(.topP))
        #expect(caps.supportedParameters.contains(.topK))
        #expect(caps.supportedParameters.contains(.repeatPenalty))
    }

    @Test func capabilities_supportsSystemPrompt() {
        #expect(OllamaBackend().capabilities.supportsSystemPrompt)
    }

    @Test func capabilities_noPromptTemplate() {
        #expect(!OllamaBackend().capabilities.requiresPromptTemplate)
    }

    // MARK: - Streaming

    @Test func streaming_yieldsTokens() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hello"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":" world"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"!"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "Say hello", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
        }

        #expect(tokens == ["Hello", " world", "!"])
    }

    @Test func streaming_withSystemPrompt_includesInMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "hi", systemPrompt: "You are a test bot.", config: .init())
        for try await _ in stream { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.first?["role"] == "system")
        #expect(messages.first?["content"] == "You are a test bot.")
    }

    @Test func streaming_doneChunk_notYielded() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // "done":true chunk should produce no token.
        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hi"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":1234}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["Hi"])
    }

    @Test func streaming_malformedLine_skipped() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine("not valid json"),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"OK"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await token in stream { tokens.append(token) }

        #expect(tokens == ["OK"])
    }

    // MARK: - Error Responses

    @Test func serverError_404_modelNotFound() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let body = Data(#"{"error":"model not found"}"#.utf8)
        MockURLProtocol.stub(url: chatURL, response: .immediate(data: body, statusCode: 404))

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream {}
            Issue.record("Expected server error")
        } catch let error as CloudBackendError {
            switch error {
            case .serverError(let code, _): #expect(code == 404)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func serverError_500_throws() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        MockURLProtocol.stub(url: chatURL, response: .immediate(data: Data(), statusCode: 500))

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream {}
            Issue.record("Expected server error")
        } catch let error as CloudBackendError {
            switch error {
            case .serverError(let code, _): #expect(code == 500)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func rateLimitError_429() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        MockURLProtocol.stub(url: chatURL, response: .immediate(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": "0"]
        ))

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream {}
            Issue.record("Expected rateLimited error")
        } catch let error as CloudBackendError {
            switch error {
            case .rateLimited: break
            default: Issue.record("Expected rateLimited, got \(error)")
            }
        }
    }

    // MARK: - Request Body

    @Test func requestBody_containsModelAndMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"hi"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "Hello there", systemPrompt: nil, config: .init())
        for try await _ in stream { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "llama3.2")
        #expect(json["stream"] as? Bool == true)

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.last?["role"] == "user")
        #expect(messages.last?["content"] == "Hello there")
    }

    // MARK: - Conversation History

    @Test func conversationHistory_usedInMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        backend.setConversationHistory([
            (role: "user", content: "First message"),
            (role: "assistant", content: "First reply"),
        ])

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "ignored when history set", systemPrompt: nil, config: .init())
        for try await _ in stream { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])

        #expect(messages.count == 2)
        #expect(messages[0]["content"] == "First message")
        #expect(messages[1]["content"] == "First reply")
    }

    // MARK: - stopGeneration

    @Test func stopGeneration_setsIsGeneratingFalse() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        backend.stopGeneration()
        #expect(!backend.isGenerating)
    }

    // MARK: - NDJSON Parsing

    @Test func extractToken_parsesContent() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":"Hello"},"done":false}"#
        #expect(OllamaBackend.extractToken(from: json) == "Hello")
    }

    @Test func extractToken_skipsEmptyContent() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":false}"#
        #expect(OllamaBackend.extractToken(from: json) == nil)
    }

    @Test func extractToken_skipsDoneChunk() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#
        #expect(OllamaBackend.extractToken(from: json) == nil)
    }

    @Test func extractToken_malformedJSON_returnsNil() {
        #expect(OllamaBackend.extractToken(from: "not json") == nil)
    }
}

// MARK: - OllamaModelListService Tests

@Suite("OllamaModelListService", .serialized)
struct OllamaModelListServiceTests {

    private func makeService() -> (OllamaModelListService, URL) {
        let session = makeMockSession()
        let service = OllamaModelListService(urlSession: session)
        let baseURL = URL(string: "http://ollama-models-\(UUID().uuidString).test")!
        return (service, baseURL)
    }

    @Test func fetchModels_parsesResponse() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let response = """
        {"models":[
            {"name":"llama3.2:8b","size":5368709120},
            {"name":"mistral:7b","size":4294967296},
            {"name":"phi3:mini","size":2147483648}
        ]}
        """
        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(response.utf8), statusCode: 200))

        let models = try await service.fetchModels(from: baseURL)

        #expect(models.count == 3)
        // Should be sorted alphabetically.
        #expect(models[0].name == "llama3.2:8b")
        #expect(models[1].name == "mistral:7b")
        #expect(models[2].name == "phi3:mini")
    }

    @Test func fetchModels_extractsQuantization() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let response = #"{"models":[{"name":"llama3.2:8b-q4_0","size":4294967296}]}"#
        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(response.utf8), statusCode: 200))

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.first?.quantization == "8b-q4_0")
    }

    @Test func fetchModels_emptyList_returnsEmpty() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(#"{"models":[]}"#.utf8), statusCode: 200))

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.isEmpty)
    }

    @Test func fetchModels_serverError_throws() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(), statusCode: 503))

        do {
            _ = try await service.fetchModels(from: baseURL)
            Issue.record("Expected error on 503 response")
        } catch let error as CloudBackendError {
            switch error {
            case .serverError(let code, _): #expect(code == 503)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func fetchModels_networkError_throws() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .error(URLError(.notConnectedToInternet)))

        do {
            _ = try await service.fetchModels(from: baseURL)
            Issue.record("Expected network error")
        } catch {
            // expected
        }
    }
}

// MARK: - OpenAICompatibleBackend Alias

@Suite("OpenAICompatibleBackend typealias")
struct OpenAICompatibleBackendTests {

    @Test func isOpenAIBackend() {
        let backend = OpenAICompatibleBackend()
        #expect(backend is OpenAIBackend)
    }
}

// MARK: - Body Extraction Helper

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

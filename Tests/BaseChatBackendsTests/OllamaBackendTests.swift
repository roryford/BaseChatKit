import Testing
import XCTest
import Foundation
@testable import BaseChatBackends
@testable import BaseChatCore
@testable import BaseChatInference
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
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
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
            try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
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
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "Say hello", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
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
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: "You are a test bot.", config: .init())
        for try await _ in stream.events { }

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
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

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
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

        #expect(tokens == ["OK"])
    }

    // MARK: - Error Responses

    @Test func serverError_404_modelNotFound() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let body = Data(#"{"error":"model not found"}"#.utf8)
        MockURLProtocol.stub(url: chatURL, response: .immediate(data: body, statusCode: 404))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
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
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
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
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected rateLimited error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
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
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "Hello there", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

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
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "ignored when history set", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

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

    // MARK: - Thinking field (issue #487)

    /// Reasoning models (qwen3, qwen3.5:4b, deepseek-r1) emit chain-of-thought in
    /// a separate `thinking` field on the `/api/chat` endpoint. The backend
    /// must surface these as `.thinkingToken` events and close with
    /// `.thinkingComplete` when thinking transitions back to empty.
    @Test func streaming_chatEndpoint_thinkingFieldEmitsThinkingEvents() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"Reasoning step 1","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"","content":"answer"},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        // Ordering: .thinkingToken → .thinkingComplete → .token
        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["Reasoning step 1"])
        #expect(tokens == ["answer"])
        #expect(completeCount == 1)

        // Verify event ordering: thinkingToken precedes thinkingComplete precedes token.
        var sawThinking = false
        var sawComplete = false
        for event in events {
            switch event {
            case .thinkingToken:
                #expect(!sawComplete, "thinkingToken must precede thinkingComplete")
                sawThinking = true
            case .thinkingComplete:
                #expect(sawThinking, "thinkingComplete must follow at least one thinkingToken")
                sawComplete = true
            case .token:
                #expect(sawComplete, "visible token must follow thinkingComplete")
            default: break
            }
        }
    }

    /// `/api/generate` surfaces reasoning at top-level `thinking` rather than
    /// under `message.thinking`. The backend must handle both endpoint shapes.
    @Test func streaming_generateEndpoint_topLevelThinkingEmitsThinkingEvents() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"response":"","thinking":"Thinking...","done":false}"#),
            ndjsonLine(#"{"response":"answer","thinking":"","done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["Thinking..."])
        #expect(tokens == ["answer"])
        #expect(completeCount == 1)
    }

    /// Actual #487 repro: reasoning model exhausts `num_predict` entirely in
    /// `<think>` and Ollama returns a single line with `done:true`,
    /// `done_reason:length`, non-empty `thinking`, and empty `response`.
    /// Previously dropped on the floor — users saw a blank message.
    @Test func streaming_thinkingOnly_thenDone_flushesThinkingComplete() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"response":"","thinking":"entire reasoning","done":true,"done_reason":"length"}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["entire reasoning"])
        #expect(completeCount == 1)
    }

    /// `config.maxThinkingTokens` caps reasoning emission so a runaway
    /// reasoning model doesn't flood the UI. Lines with thinking beyond the
    /// cap are dropped; visible content still flows through.
    @Test func streaming_maxThinkingTokens_capsEmission() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // 5 thinking-bearing lines, then transition to visible answer.
        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t1","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t2","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t3","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t4","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t5","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"","content":"answer"},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxThinkingTokens = 2
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }

        // Only the first 2 thinking chunks emit; t3, t4, t5 are dropped.
        #expect(thinkingTokens == ["t1", "t2"])
        #expect(tokens == ["answer"])
    }

    // MARK: - NDJSON parseLine

    @Test func parseLine_chatThinking() {
        let json = #"{"message":{"role":"assistant","thinking":"reasoning","content":"hi"},"done":false}"#
        let parsed = try? #require(OllamaBackend.parseLine(json))
        #expect(parsed?.thinking == "reasoning")
        #expect(parsed?.content == "hi")
        #expect(parsed?.done == false)
    }

    @Test func parseLine_generateTopLevelThinking() {
        let json = #"{"response":"answer","thinking":"reasoning","done":true}"#
        let parsed = try? #require(OllamaBackend.parseLine(json))
        #expect(parsed?.thinking == "reasoning")
        #expect(parsed?.content == "answer")
        #expect(parsed?.done == true)
    }

    @Test func extractThinking_returnsThinkingField() {
        let json = #"{"response":"","thinking":"reasoning","done":false}"#
        #expect(OllamaBackend.extractThinking(from: json) == "reasoning")
    }

    @Test func extractThinking_emptyThinking_returnsNil() {
        let json = #"{"response":"hi","thinking":"","done":false}"#
        #expect(OllamaBackend.extractThinking(from: json) == nil)
    }

    @Test func extractThinking_noThinkingField_returnsNil() {
        let json = #"{"message":{"role":"assistant","content":"hi"},"done":false}"#
        #expect(OllamaBackend.extractThinking(from: json) == nil)
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
        defer { MockURLProtocol.unstub(url: tagsURL) }

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
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.first?.quantization == "8b-q4_0")
    }

    @Test func fetchModels_emptyList_returnsEmpty() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(#"{"models":[]}"#.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.isEmpty)
    }

    @Test func fetchModels_serverError_throws() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(), statusCode: 503))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        do {
            _ = try await service.fetchModels(from: baseURL)
            Issue.record("Expected error on 503 response")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
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
        defer { MockURLProtocol.unstub(url: tagsURL) }

        do {
            _ = try await service.fetchModels(from: baseURL)
            Issue.record("Expected network error")
        } catch {
            // expected
        }
    }
}

// MARK: - Backend Contract

/// XCTestCase subclass for BackendContractChecks (which uses XCTest assertions).
final class OllamaBackendContractTests: XCTestCase {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { OllamaBackend() }
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

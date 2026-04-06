import XCTest
import BaseChatCore
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for OpenAIBackend configuration, state, and capabilities.
final class OpenAIBackendTests: XCTestCase {

    // MARK: - Init & State

    func test_init_defaultState() {
        let backend = OpenAIBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Capabilities

    func test_capabilities_supportsTemperatureAndTopP() {
        let backend = OpenAIBackend()
        let caps = backend.capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
    }

    func test_capabilities_doesNotRequirePromptTemplate() {
        let backend = OpenAIBackend()
        XCTAssertFalse(backend.capabilities.requiresPromptTemplate,
                       "OpenAI handles chat templating server-side")
    }

    func test_capabilities_supportsSystemPrompt() {
        let backend = OpenAIBackend()
        XCTAssertTrue(backend.capabilities.supportsSystemPrompt)
    }

    // MARK: - Model Lifecycle

    func test_loadModel_withoutConfiguration_throws() async {
        let backend = OpenAIBackend()
        do {
            try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
            XCTFail("Should throw when no base URL is configured")
        } catch {
            // Expected — no baseURL configured
        }
    }

    func test_configure_thenLoadModel_succeeds() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)
    }

    func test_unloadModel_clearsState() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)

        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_generate_withoutLoading_throws() {
        let backend = OpenAIBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())
        )
    }

    func test_stopGeneration_setsIsGeneratingFalse() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        // stopGeneration should be safe to call even when not generating
        backend.stopGeneration()
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Token Extraction (indirect via SSE + JSON)

    /// Verifies that the OpenAI JSON format can round-trip through SSE parsing.
    /// Since extractToken is private, we test the format indirectly by verifying
    /// the JSON structure matches what the parser expects.
    func test_extractToken_validJSON() {
        // The expected OpenAI streaming chunk format
        let json = #"{"choices":[{"delta":{"content":"token"}}]}"#
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(parsed)
        let choices = parsed?["choices"] as? [[String: Any]]
        XCTAssertNotNil(choices)
        let delta = choices?.first?["delta"] as? [String: Any]
        XCTAssertNotNil(delta)
        let content = delta?["content"] as? String
        XCTAssertEqual(content, "token")
    }

    // MARK: - Protocol Conformance

    func test_conformsToConversationHistoryReceiver() {
        let backend = OpenAIBackend()
        XCTAssertTrue(backend is ConversationHistoryReceiver,
                      "OpenAIBackend should conform to ConversationHistoryReceiver")
    }

    func test_conformsToTokenUsageProvider() {
        let backend = OpenAIBackend()
        XCTAssertTrue(backend is TokenUsageProvider,
                      "OpenAIBackend should conform to TokenUsageProvider")
    }

    func test_setConversationHistory_storesMessages() {
        let backend = OpenAIBackend()
        let history: [(role: String, content: String)] = [
            (role: "user", content: "Hello"),
            (role: "assistant", content: "Hi!")
        ]
        backend.setConversationHistory(history)
        XCTAssertEqual(backend.conversationHistory?.count, 2)
        XCTAssertEqual(backend.conversationHistory?[0].content, "Hello")
    }

    func test_castAsProtocols_succeeds() {
        let backend: any InferenceBackend = OpenAIBackend()
        XCTAssertNotNil(backend as? ConversationHistoryReceiver,
                        "Casting InferenceBackend to ConversationHistoryReceiver should succeed")
        XCTAssertNotNil(backend as? TokenUsageProvider,
                        "Casting InferenceBackend to TokenUsageProvider should succeed")
    }
}

// MARK: - Multi-turn History Serialisation

extension OpenAIBackendTests {

    func test_conversationHistory_includedInRequestBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = OpenAIBackend(urlSession: session)
        let url = URL(string: "https://openai-history-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-test", modelName: "gpt-4o-mini")
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        backend.setConversationHistory([
            (role: "user", content: "What is 2+2?"),
            (role: "assistant", content: "4"),
        ])

        let chunk = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8)
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(prompt: "And 3+3?", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url?.host == url.host })
        // URLSession may convert httpBody → httpBodyStream during transmission.
        let body: Data
        if let direct = captured?.httpBody {
            body = direct
        } else if let stream = captured?.httpBodyStream {
            var bodyData = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { bodyData.append(buffer, count: read) }
            }
            stream.close()
            body = bodyData
        } else {
            XCTFail("Captured request has no body")
            return
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        // When conversationHistory is set, its messages are used directly as the request body.
        XCTAssertGreaterThanOrEqual(messages.count, 2, "History messages must be included in request")
        XCTAssertEqual(messages[0]["content"] as? String, "What is 2+2?")
        XCTAssertEqual(messages[1]["content"] as? String, "4")
    }
}

// MARK: - stopGeneration() Mid-stream Cancellation

extension OpenAIBackendTests {

    func test_stopGeneration_cancelsActiveStream() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = OpenAIBackend(urlSession: session)
        let url = URL(string: "https://openai-cancel-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-test", modelName: "gpt-4o-mini")
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        var chunks: [Data] = (0..<20).map { i in
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"tok\(i)\"}}]}\n\n".utf8)
        }
        chunks.append(Data("data: [DONE]\n\n".utf8))

        MockURLProtocol.stub(url: url, response: .asyncSSE(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())

        var tokenCount = 0
        do {
            for try await _ in stream.events {
                tokenCount += 1
                if tokenCount == 2 {
                    backend.stopGeneration()
                }
            }
        } catch {
            // Cancellation may throw — that's acceptable
        }

        XCTAssertFalse(backend.isGenerating, "isGenerating must be false after stopGeneration")
        XCTAssertLessThan(tokenCount, 20, "Stream should have been cancelled before all tokens arrived")
    }
}

// MARK: - Keychain-backed configure() path

extension OpenAIBackendTests {

    func test_configure_keychainPath_loadModelSucceeds() async throws {
        let testAccount = "BaseChatKit.test.openai.\(UUID().uuidString)"
        KeychainService.store(key: "sk-test-keychain-key", account: testAccount)
        defer { KeychainService.delete(account: testAccount) }

        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            keychainAccount: testAccount,
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)
    }
}

// MARK: - Backend Contract

extension OpenAIBackendTests {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { OpenAIBackend() }
    }
}


import XCTest
import BaseChatCore
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for ClaudeBackend configuration, state, and capabilities.
final class ClaudeBackendTests: XCTestCase {

    // MARK: - Init & State

    func test_init_defaultState() {
        let backend = ClaudeBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Capabilities

    func test_capabilities_supportsTemperatureAndTopP() {
        let backend = ClaudeBackend()
        let caps = backend.capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
    }

    func test_capabilities_noRepeatPenalty() {
        let backend = ClaudeBackend()
        XCTAssertFalse(backend.capabilities.supportedParameters.contains(.repeatPenalty),
                       "Claude API does not support repeat_penalty")
    }

    func test_capabilities_highContextLimit() {
        let backend = ClaudeBackend()
        XCTAssertEqual(backend.capabilities.maxContextTokens, 200_000,
                       "Claude should support 200K context")
    }

    // MARK: - Model Lifecycle

    func test_loadModel_withoutAPIKey_throws() async {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: nil,
            modelName: "claude-sonnet-4-20250514"
        )

        do {
            try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
            XCTFail("Should throw missingAPIKey when no API key is configured")
        } catch let error as CloudBackendError {
            if case .missingAPIKey = error {
                // Expected
            } else {
                XCTFail("Expected missingAPIKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_loadModel_withAPIKey_succeeds() async throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-test-key",
            modelName: "claude-sonnet-4-20250514"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)
    }

    func test_unloadModel_clearsState() async throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-test-key",
            modelName: "claude-sonnet-4-20250514"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)

        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_generate_withoutLoading_throws() {
        let backend = ClaudeBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())
        )
    }

    // MARK: - Protocol Conformance

    func test_conformsToConversationHistoryReceiver() {
        let backend = ClaudeBackend()
        XCTAssertTrue(backend is ConversationHistoryReceiver,
                      "ClaudeBackend should conform to ConversationHistoryReceiver")
    }

    func test_conformsToTokenUsageProvider() {
        let backend = ClaudeBackend()
        XCTAssertTrue(backend is TokenUsageProvider,
                      "ClaudeBackend should conform to TokenUsageProvider")
    }

    func test_setConversationHistory_storesMessages() {
        let backend = ClaudeBackend()
        let history: [(role: String, content: String)] = [
            (role: "user", content: "Hello"),
            (role: "assistant", content: "Hi there!")
        ]
        backend.setConversationHistory(history)
        XCTAssertEqual(backend.conversationHistory?.count, 2)
        XCTAssertEqual(backend.conversationHistory?[0].role, "user")
        XCTAssertEqual(backend.conversationHistory?[1].content, "Hi there!")
    }

    func test_lastUsage_nilByDefault() {
        let backend = ClaudeBackend()
        XCTAssertNil(backend.lastUsage, "lastUsage should be nil before any generation")
    }

    func test_castAsProtocols_succeeds() {
        let backend: any InferenceBackend = ClaudeBackend()
        XCTAssertNotNil(backend as? ConversationHistoryReceiver,
                        "Casting InferenceBackend to ConversationHistoryReceiver should succeed")
        XCTAssertNotNil(backend as? TokenUsageProvider,
                        "Casting InferenceBackend to TokenUsageProvider should succeed")
    }
}

// MARK: - Multi-turn History Serialisation

extension ClaudeBackendTests {

    func test_conversationHistory_includedInRequestBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        let url = URL(string: "https://api.anthropic.com")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        backend.setConversationHistory([
            (role: "user", content: "What is 2+2?"),
            (role: "assistant", content: "4"),
        ])

        MockURLProtocol.reset()
        let chunk = Data("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\ndata: {"type":"message_stop"}\n\n
            """.utf8)
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))

        let stream = try backend.generate(prompt: "And 3+3?", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream { }

        let captured = MockURLProtocol.capturedRequests.first
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

extension ClaudeBackendTests {

    func test_stopGeneration_cancelsActiveStream() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        let url = URL(string: "https://api.anthropic.com")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        var chunks: [Data] = (0..<20).map { i in
            Data("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"tok\(i)\"}}\n\n".utf8)
        }
        chunks.append(Data("data: {\"type\":\"message_stop\"}\n\n".utf8))

        MockURLProtocol.reset()
        MockURLProtocol.stub(url: url, response: .asyncSSE(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())

        var tokenCount = 0
        do {
            for try await _ in stream {
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

extension ClaudeBackendTests {

    func test_configure_keychainPath_loadModelSucceeds() async throws {
        let testAccount = "BaseChatKit.test.claude.\(UUID().uuidString)"
        // Claude's loadModel validates the API key, so we must store a real value.
        KeychainService.store(key: "sk-ant-test-keychain-key", account: testAccount)
        defer { KeychainService.delete(account: testAccount) }

        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            keychainAccount: testAccount,
            modelName: "claude-sonnet-4-20250514"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)
    }
}

// MARK: - BackendContractSuite

extension ClaudeBackendTests: BackendContractSuite {
    func makeBackend() -> ClaudeBackend { ClaudeBackend() }
}


import XCTest
import BaseChatCore
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

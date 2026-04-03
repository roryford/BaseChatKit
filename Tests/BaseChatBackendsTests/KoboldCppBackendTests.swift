import XCTest
import BaseChatCore
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for KoboldCppBackend configuration, state, and capabilities.
final class KoboldCppBackendTests: XCTestCase {

    // MARK: - Helpers

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
    }

    // MARK: - Init & State

    func test_init_defaultState() {
        let backend = KoboldCppBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Capabilities

    func test_capabilities_supportsExpectedParameters() {
        let backend = KoboldCppBackend()
        let caps = backend.capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
        XCTAssertTrue(caps.supportedParameters.contains(.topK))
        XCTAssertTrue(caps.supportedParameters.contains(.typicalP))
        XCTAssertTrue(caps.supportedParameters.contains(.repeatPenalty))
    }

    func test_capabilities_requiresPromptTemplate() {
        let backend = KoboldCppBackend()
        XCTAssertTrue(backend.capabilities.requiresPromptTemplate,
                      "KoboldCpp uses a flat prompt — caller must format with a template")
    }

    func test_capabilities_doesNotSupportSystemPrompt() {
        let backend = KoboldCppBackend()
        XCTAssertFalse(backend.capabilities.supportsSystemPrompt,
                       "System prompt is baked into the formatted prompt, not sent separately")
    }

    // MARK: - Model Lifecycle

    func test_loadModel_withoutConfiguration_throws() async {
        let backend = KoboldCppBackend()
        do {
            try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
            XCTFail("Should throw when no base URL is configured")
        } catch {
            // Expected — no baseURL configured
        }
    }

    func test_configure_thenLoadModel_succeeds() async throws {
        let session = makeMockSession()
        let backend = KoboldCppBackend(urlSession: session)
        let baseURL = URL(string: "http://localhost:5001")!

        // Stub the max_context_length endpoint
        let contextURL = baseURL.appendingPathComponent("api/v1/config/max_context_length")
        let contextResponse = Data(#"{"value":8192}"#.utf8)
        MockURLProtocol.stub(url: contextURL, response: .immediate(data: contextResponse, statusCode: 200))

        backend.configure(baseURL: baseURL, modelName: "koboldcpp")
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)
        // Context length should have been updated from the server response
        XCTAssertEqual(backend.capabilities.maxContextTokens, 8192)
    }

    func test_unloadModel_clearsState() async throws {
        let session = makeMockSession()
        let backend = KoboldCppBackend(urlSession: session)
        let baseURL = URL(string: "http://localhost:5001")!

        let contextURL = baseURL.appendingPathComponent("api/v1/config/max_context_length")
        MockURLProtocol.stub(url: contextURL, response: .immediate(data: Data(#"{"value":4096}"#.utf8), statusCode: 200))

        backend.configure(baseURL: baseURL)
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)

        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
        // Context length resets to default after unload
        XCTAssertEqual(backend.capabilities.maxContextTokens, 4096)
    }

    func test_generate_withoutLoading_throws() {
        let backend = KoboldCppBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())
        )
    }

    // MARK: - Grammar Constraint

    func test_grammarConstraint_isKoboldCppSpecific() {
        let backend = KoboldCppBackend()
        XCTAssertNil(backend.grammarConstraint, "Grammar constraint should be nil by default")

        let gbnf = #"root ::= "yes" | "no""#
        backend.grammarConstraint = gbnf
        XCTAssertEqual(backend.grammarConstraint, gbnf)
    }

    // MARK: - Protocol Conformance

    func test_conformsToConversationHistoryReceiver() {
        let backend = KoboldCppBackend()
        XCTAssertTrue(backend is ConversationHistoryReceiver,
                      "KoboldCppBackend should conform to ConversationHistoryReceiver")
    }

    func test_setConversationHistory_storesMessages() {
        let backend = KoboldCppBackend()
        let history: [(role: String, content: String)] = [
            (role: "user", content: "Hello"),
            (role: "assistant", content: "Hi!")
        ]
        backend.setConversationHistory(history)
        XCTAssertEqual(backend.conversationHistory?.count, 2)
        XCTAssertEqual(backend.conversationHistory?[0].content, "Hello")
    }

    func test_stopGeneration_setsIsGeneratingFalse() async throws {
        let session = makeMockSession()
        let backend = KoboldCppBackend(urlSession: session)
        let baseURL = URL(string: "http://localhost:5001")!

        let contextURL = baseURL.appendingPathComponent("api/v1/config/max_context_length")
        MockURLProtocol.stub(url: contextURL, response: .immediate(data: Data(#"{"value":4096}"#.utf8), statusCode: 200))

        backend.configure(baseURL: baseURL)
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        // stopGeneration should be safe to call even when not generating
        backend.stopGeneration()
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Backend Contract

    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { KoboldCppBackend() }
    }
}

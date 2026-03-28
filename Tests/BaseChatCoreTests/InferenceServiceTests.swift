import XCTest
@testable import BaseChatCore

/// Tests for the InferenceService orchestrator and backend behavior.
///
/// These tests verify service-level logic without loading real models.
/// Concrete backend tests (LlamaBackend, MLXBackend, FoundationBackend) belong
/// in BaseChatBackendsTests since those types live in BaseChatBackends.
final class InferenceServiceTests: XCTestCase {

    // MARK: - InferenceService

    func test_generate_noModelLoaded_throwsError() {
        let service = InferenceService()
        XCTAssertThrowsError(try service.generate(messages: [("user", "hello")]))
    }

    func test_unloadModel_resetsState() {
        let service = InferenceService()
        service.unloadModel()
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertFalse(service.isGenerating)
        XCTAssertNil(service.activeBackendName)
    }

    // MARK: - Mock Backend via #if DEBUG init

    func test_generate_withMockBackend_streamsTokens() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Once", " upon", " a", " time"]

        let service = InferenceService(backend: mock, name: "Mock")
        XCTAssertTrue(service.isModelLoaded)

        let stream = try service.generate(messages: [("user", "Tell me a story")])

        var collected: [String] = []
        for try await token in stream {
            collected.append(token)
        }

        XCTAssertEqual(collected, ["Once", " upon", " a", " time"],
                        "Should stream all tokens from the mock backend")
        XCTAssertEqual(mock.generateCallCount, 1, "Should have called generate once")
    }

    func test_capabilities_delegatesToBackend() {
        let customCaps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 2048,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false
        )
        let mock = MockInferenceBackend(capabilities: customCaps)
        let service = InferenceService(backend: mock, name: "Mock")

        let caps = service.capabilities
        XCTAssertNotNil(caps, "Capabilities should not be nil when backend is loaded")
        XCTAssertEqual(caps?.maxContextTokens, 2048)
        XCTAssertTrue(caps?.requiresPromptTemplate == true)
        XCTAssertFalse(caps?.supportsSystemPrompt == true)
        XCTAssertEqual(caps?.supportedParameters, [.temperature])
    }

    func test_promptTemplate_appliedForTemplateBackend() throws {
        let templateCaps = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: true,
            supportsSystemPrompt: true
        )
        let mock = MockInferenceBackend(capabilities: templateCaps)
        mock.isModelLoaded = true

        let service = InferenceService(backend: mock, name: "Mock")
        service.selectedPromptTemplate = .chatML

        // Generate with messages; since requiresPromptTemplate is true,
        // InferenceService should format them using the selected template.
        let _ = try service.generate(
            messages: [("user", "Hello")],
            systemPrompt: "Be helpful."
        )

        // The prompt passed to the backend should be ChatML-formatted.
        XCTAssertNotNil(mock.lastPrompt, "Backend should have received a prompt")
        XCTAssertTrue(mock.lastPrompt?.contains("<|im_start|>") == true,
                      "Prompt should be formatted with ChatML template, got: \(mock.lastPrompt ?? "nil")")
        // System prompt should be baked into the formatted string, so effectiveSystemPrompt is nil.
        XCTAssertNil(mock.lastSystemPrompt,
                     "System prompt should be nil when baked into template")
    }

    func test_capabilities_nilWhenNoBackend() {
        let service = InferenceService()
        XCTAssertNil(service.capabilities, "Capabilities should be nil when no backend is loaded")
    }

    // MARK: - GenerationConfig

    func test_generationConfig_defaults() {
        let config = GenerationConfig()
        XCTAssertEqual(config.temperature, 0.7)
        XCTAssertEqual(config.topP, 0.9)
        XCTAssertEqual(config.repeatPenalty, 1.1)
        XCTAssertEqual(config.maxTokens, 512)
    }

    // MARK: - ModelType backend selection
    // NOTE: test_inferenceService_backendName_gguf requires LlamaBackend from BaseChatBackends.
    // That test belongs in BaseChatBackendsTests. Keeping a mock-based equivalent here:

    func test_inferenceService_backendName_reflectsLoadedBackend() {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "MockBackend")
        XCTAssertEqual(service.activeBackendName, "MockBackend")
    }
}

import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

/// Tests for the InferenceService orchestrator and backend behavior.
///
/// These tests verify service-level logic without loading real models.
/// Concrete backend tests (LlamaBackend, MLXBackend, FoundationBackend) belong
/// in BaseChatBackendsTests since those types live in BaseChatBackends.
@MainActor
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

    // MARK: - loadCloudBackend

    func test_loadCloudBackend_invalidURL_throwsError() async {
        let service = InferenceService()
        // A null byte makes URL(string:) return nil on all Apple platforms.
        let badURL = "http://foo\0bar"
        let endpoint = APIEndpoint(name: "Bad", provider: .custom, baseURL: badURL)

        do {
            try await service.loadCloudBackend(from: endpoint)
            XCTFail("Expected CloudBackendError.invalidURL to be thrown")
        } catch CloudBackendError.invalidURL(let raw) {
            XCTAssertEqual(raw, badURL)
        } catch {
            XCTFail("Expected CloudBackendError.invalidURL, got \(error)")
        }
    }

    func test_loadCloudBackend_noFactoryRegistered_throwsError() async {
        let service = InferenceService()
        let endpoint = APIEndpoint(name: "Ollama", provider: .ollama)

        do {
            try await service.loadCloudBackend(from: endpoint)
            XCTFail("Expected InferenceError.inferenceFailure to be thrown")
        } catch InferenceError.inferenceFailure {
            // expected
        } catch {
            XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
        }
    }

    func test_loadCloudBackend_setsIsModelLoaded() async throws {
        let service = InferenceService()
        let mock = MockInferenceBackend()

        service.registerCloudBackendFactory { _ in mock }

        let endpoint = APIEndpoint(name: "Ollama", provider: .ollama)
        try await service.loadCloudBackend(from: endpoint)

        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, APIProvider.ollama.rawValue)
        XCTAssertEqual(mock.loadModelCallCount, 1)
    }

    func test_loadCloudBackend_unloadsExistingModel() async throws {
        let firstMock = MockInferenceBackend()
        let service = InferenceService(backend: firstMock, name: "First")

        let cloudMock = MockInferenceBackend()
        service.registerCloudBackendFactory { _ in cloudMock }

        let endpoint = APIEndpoint(name: "Ollama", provider: .ollama)
        try await service.loadCloudBackend(from: endpoint)

        // The old backend should have been unloaded.
        XCTAssertEqual(firstMock.unloadCallCount, 1, "Old backend should be unloaded")
        // New backend is active.
        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, APIProvider.ollama.rawValue)
    }

    // MARK: - Cloud backend interop

    func test_generate_cloudBackend_passesConversationHistory() throws {
        let mock = MockConversationHistoryBackend()
        let service = InferenceService(backend: mock, name: "CloudMock")

        let messages: [(role: String, content: String)] = [
            ("user", "Hello"),
            ("assistant", "Hi there"),
            ("user", "How are you?")
        ]

        let _ = try service.generate(messages: messages)

        XCTAssertNotNil(mock.receivedHistory, "setConversationHistory should have been called")
        let received = mock.receivedHistory ?? []
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[0].role, "user")
        XCTAssertEqual(received[0].content, "Hello")
        XCTAssertEqual(received[2].content, "How are you?")
    }

    func test_generate_cloudBackend_capturesTokenUsage() async throws {
        let mock = MockTokenUsageBackend()
        mock.stubbedUsage = (promptTokens: 42, completionTokens: 17)
        let service = InferenceService(backend: mock, name: "CloudMock")

        let stream = try service.generate(messages: [("user", "ping")])
        // Drain the stream so generation completes.
        for try await _ in stream {}

        let usage = service.lastTokenUsage
        XCTAssertNotNil(usage, "lastTokenUsage should be populated after generation")
        XCTAssertEqual(usage?.promptTokens, 42)
        XCTAssertEqual(usage?.completionTokens, 17)
    }

    // MARK: - Backend factory fallback chain

    func test_createBackend_firstFactoryWins() async throws {
        let service = InferenceService()

        var firstCallCount = 0
        var secondCallCount = 0

        let firstMock = MockInferenceBackend()
        service.registerBackendFactory { modelType in
            guard modelType == .foundation else { return nil }
            firstCallCount += 1
            return firstMock
        }

        let secondMock = MockInferenceBackend()
        service.registerBackendFactory { modelType in
            guard modelType == .foundation else { return nil }
            secondCallCount += 1
            return secondMock
        }

        let modelInfo = ModelInfo(
            name: "Foundation",
            fileName: "Built-in",
            url: URL(fileURLWithPath: "/"),
            fileSize: 0,
            modelType: .foundation
        )
        try await service.loadModel(from: modelInfo)

        XCTAssertEqual(firstCallCount, 1, "First factory should be called once")
        XCTAssertEqual(secondCallCount, 0, "Second factory should never be called when first wins")
        XCTAssertEqual(firstMock.loadModelCallCount, 1, "First factory's backend should be loaded")
        XCTAssertEqual(secondMock.loadModelCallCount, 0, "Second factory's backend should not be loaded")
    }

    func test_createBackend_firstFactoryRejectsSecondHandles() async throws {
        let service = InferenceService()

        var firstCallCount = 0
        service.registerBackendFactory { modelType in
            firstCallCount += 1
            return nil  // always rejects
        }

        var secondCallCount = 0
        let secondMock = MockInferenceBackend()
        service.registerBackendFactory { modelType in
            guard modelType == .gguf else { return nil }
            secondCallCount += 1
            return secondMock
        }

        let modelInfo = ModelInfo(
            name: "Test GGUF",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 0,
            modelType: .gguf
        )
        try await service.loadModel(from: modelInfo)

        XCTAssertEqual(firstCallCount, 1, "First factory should be called once")
        XCTAssertEqual(secondCallCount, 1, "Second factory should be called after first rejects")
        XCTAssertEqual(secondMock.loadModelCallCount, 1, "Second factory's backend should be loaded")
        XCTAssertTrue(service.isModelLoaded)
    }

    func test_createBackend_allFactoriesReturnNil_throwsError() async {
        let service = InferenceService()

        service.registerBackendFactory { _ in nil }
        service.registerBackendFactory { _ in nil }

        let modelInfo = ModelInfo(
            name: "Unknown",
            fileName: "model.gguf",
            url: URL(fileURLWithPath: "/tmp/model.gguf"),
            fileSize: 0,
            modelType: .gguf
        )

        do {
            try await service.loadModel(from: modelInfo)
            XCTFail("Expected InferenceError.inferenceFailure to be thrown")
        } catch InferenceError.inferenceFailure {
            // expected
        } catch {
            XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
        }
    }

    func test_registerCloudBackendFactory_fallsBackToSecond() async throws {
        let service = InferenceService()

        var firstCallCount = 0
        service.registerCloudBackendFactory { provider in
            firstCallCount += 1
            return nil  // always rejects
        }

        var secondCallCount = 0
        let secondMock = MockInferenceBackend()
        service.registerCloudBackendFactory { provider in
            guard provider == .ollama else { return nil }
            secondCallCount += 1
            return secondMock
        }

        let endpoint = APIEndpoint(name: "Ollama", provider: .ollama)
        try await service.loadCloudBackend(from: endpoint)

        XCTAssertEqual(firstCallCount, 1, "First cloud factory should be called once")
        XCTAssertEqual(secondCallCount, 1, "Second cloud factory should be called after first rejects")
        XCTAssertEqual(secondMock.loadModelCallCount, 1, "Second cloud factory's backend should be loaded")
        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, APIProvider.ollama.rawValue)
    }

    // MARK: - TokenizerVendor

    func test_tokenizer_nilWhenNoBackendLoaded() {
        let service = InferenceService()
        XCTAssertNil(service.tokenizer, "tokenizer should be nil when no backend is loaded")
    }

    func test_tokenizer_nilForNonVendorBackend() {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "Mock")
        XCTAssertNil(service.tokenizer, "tokenizer should be nil for backends that don't conform to TokenizerVendor")
    }

    func test_tokenizer_returnedForVendorBackend() {
        let mock = MockTokenizerVendorBackend()
        let service = InferenceService(backend: mock, name: "VendorMock")
        XCTAssertNotNil(service.tokenizer, "tokenizer should be non-nil for TokenizerVendor backends")
    }

    func test_tokenizer_delegatesToBackendTokenizerProvider() {
        let mock = MockTokenizerVendorBackend()
        mock.stubbedTokenCount = 42
        let service = InferenceService(backend: mock, name: "VendorMock")

        let count = service.tokenizer?.tokenCount("anything")
        XCTAssertEqual(count, 42, "InferenceService should delegate tokenCount to the backend's tokenizer")
    }

    func test_tokenizer_nilAfterUnload() {
        let mock = MockTokenizerVendorBackend()
        let service = InferenceService(backend: mock, name: "VendorMock")
        XCTAssertNotNil(service.tokenizer)

        service.unloadModel()
        XCTAssertNil(service.tokenizer, "tokenizer should be nil after backend is unloaded")
    }

    func test_loadModel_replacesExistingBackend() async throws {
        // Load model A first using the #if DEBUG init.
        let firstMock = MockInferenceBackend()
        let service = InferenceService(backend: firstMock, name: "ModelA")
        XCTAssertTrue(service.isModelLoaded)

        // Register a factory for the second model.
        let secondMock = MockInferenceBackend()
        service.registerBackendFactory { _ in secondMock }

        let modelInfo = ModelInfo(
            name: "ModelB",
            fileName: "model-b.gguf",
            url: URL(fileURLWithPath: "/tmp/model-b.gguf"),
            fileSize: 0,
            modelType: .gguf
        )
        try await service.loadModel(from: modelInfo)

        XCTAssertEqual(firstMock.unloadCallCount, 1, "First backend's unloadModel() should be called exactly once")
        XCTAssertEqual(secondMock.loadModelCallCount, 1, "Second backend should be loaded")
        XCTAssertTrue(service.isModelLoaded)
    }
}

// MARK: - Local mock types for cloud interop tests

/// A mock backend that also adopts ConversationHistoryReceiver.
private final class MockConversationHistoryBackend: InferenceBackend,
                                                    ConversationHistoryReceiver,
                                                    @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var receivedHistory: [(role: String, content: String)]?

    func setConversationHistory(_ messages: [(role: String, content: String)]) {
        receivedHistory = messages
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func stopGeneration() {}
    func unloadModel() {}
}

/// A mock backend that also adopts TokenUsageProvider.
private final class MockTokenUsageBackend: InferenceBackend,
                                           TokenUsageProvider,
                                           @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var stubbedUsage: (promptTokens: Int, completionTokens: Int)?
    var lastUsage: (promptTokens: Int, completionTokens: Int)? { stubbedUsage }

    func loadModel(from url: URL, contextSize: Int32) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func stopGeneration() {}
    func unloadModel() {}
}

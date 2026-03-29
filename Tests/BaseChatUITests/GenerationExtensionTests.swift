import XCTest
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

// MARK: - Token Usage Mock

/// A standalone mock backend that adopts TokenUsageProvider so that
/// InferenceService.lastTokenUsage returns non-nil after generation.
/// Cannot subclass MockInferenceBackend (it is final), so this duplicates
/// the minimal behaviour needed for token-usage tests.
private final class TokenTrackingMockBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
    var isModelLoaded = true
    var isGenerating = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var tokensToYield: [String] = []
    var lastUsage: (promptTokens: Int, completionTokens: Int)?

    /// Set this before generation; the usage is "recorded" after tokens finish.
    var usageToReport: (promptTokens: Int, completionTokens: Int)?

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        isGenerating = true
        let tokens = tokensToYield
        let usage = usageToReport

        return AsyncThrowingStream { [weak self] continuation in
            Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                self?.lastUsage = usage
                self?.isGenerating = false
                continuation.finish()
            }
        }
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false; isGenerating = false }
}

// MARK: - Error Mock

/// A mock backend whose stream throws an error mid-generation.
private final class StreamErrorMockBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded = true
    var isGenerating = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var streamError: Error = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "stream boom"])

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> AsyncThrowingStream<String, Error> {
        isGenerating = true
        let error = streamError
        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                continuation.yield("partial")
                self?.isGenerating = false
                continuation.finish(throwing: error)
            }
        }
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false; isGenerating = false }
}

// MARK: - Tests

@MainActor
final class GenerationExtensionTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    // MARK: - Helpers

    /// Build a view model with an arbitrary mock backend pre-loaded.
    private func makeVM(
        backend: MockInferenceBackend,
        name: String = "Mock"
    ) -> ChatViewModel {
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: name)
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSession(title: "Test")
        return vm
    }

    /// Build a view model with a non-MockInferenceBackend.
    private func makeVM(
        rawBackend: any InferenceBackend,
        name: String = "Mock"
    ) -> ChatViewModel {
        let service = InferenceService(backend: rawBackend, name: name)
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSession(title: "Test")
        return vm
    }

    // MARK: - 1. Token Usage Capture

    func test_tokenUsage_capturedOnAssistantMessage() async {
        let mock = TokenTrackingMockBackend()
        mock.tokensToYield = ["Hello", " there"]
        mock.usageToReport = (promptTokens: 10, completionTokens: 5)
        let vm = makeVM(rawBackend: mock)

        vm.inputText = "Hi"
        await vm.sendMessage()

        let assistant = vm.messages.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistant, "Should have an assistant message")
        XCTAssertEqual(assistant?.promptTokens, 10, "promptTokens should be captured from backend usage")
        XCTAssertEqual(assistant?.completionTokens, 5, "completionTokens should be captured from backend usage")
    }

    func test_tokenUsage_nilWhenBackendDoesNotProvide() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Reply"]
        let vm = makeVM(backend: mock)

        vm.inputText = "Hi"
        await vm.sendMessage()

        let assistant = vm.messages.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistant)
        XCTAssertNil(assistant?.promptTokens, "promptTokens should be nil when backend is not a TokenUsageProvider")
        XCTAssertNil(assistant?.completionTokens, "completionTokens should be nil when backend is not a TokenUsageProvider")
    }

    // MARK: - 2. Upgrade Hint Logic

    func test_upgradeHint_triggersWhenAllConditionsMet() async {
        // Save and restore the shared configuration to avoid leaking between tests.
        let originalConfig = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfig }

        BaseChatConfiguration.shared.features = BaseChatConfiguration.Features(showUpgradeHint: true)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello"]
        // Backend name must be "Apple" to trigger the hint.
        let vm = makeVM(backend: mock, name: "Apple")

        var hintCallbackCalled = false
        vm.onUpgradeHintTriggered = { hintCallbackCalled = true }

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertTrue(vm.showUpgradeHint, "showUpgradeHint should be true after first assistant response with Apple backend")
        XCTAssertTrue(hintCallbackCalled, "onUpgradeHintTriggered callback should fire")
    }

    func test_upgradeHint_doesNotTriggerWhenFeatureFlagDisabled() async {
        let originalConfig = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfig }

        BaseChatConfiguration.shared.features = BaseChatConfiguration.Features(showUpgradeHint: false)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello"]
        let vm = makeVM(backend: mock, name: "Apple")

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertFalse(vm.showUpgradeHint, "showUpgradeHint should remain false when feature flag is disabled")
    }

    func test_upgradeHint_doesNotTriggerForNonAppleBackend() async {
        let originalConfig = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfig }

        BaseChatConfiguration.shared.features = BaseChatConfiguration.Features(showUpgradeHint: true)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello"]
        let vm = makeVM(backend: mock, name: "MLX")

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertFalse(vm.showUpgradeHint, "showUpgradeHint should remain false for non-Apple backends")
    }

    func test_upgradeHint_doesNotTriggerOnSecondAssistantResponse() async {
        let originalConfig = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfig }

        BaseChatConfiguration.shared.features = BaseChatConfiguration.Features(showUpgradeHint: true)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["First"]
        let vm = makeVM(backend: mock, name: "Apple")

        // First message triggers the hint.
        vm.inputText = "Hi"
        await vm.sendMessage()
        XCTAssertTrue(vm.showUpgradeHint)

        // Reset the hint flag to simulate checking second-time behavior.
        // The code checks `!showUpgradeHint`, so once set it won't trigger again.
        // Send a second message: hint should already be true, callback should not re-fire.
        var secondCallback = false
        vm.onUpgradeHintTriggered = { secondCallback = true }

        mock.tokensToYield = ["Second"]
        vm.inputText = "Another"
        await vm.sendMessage()

        // showUpgradeHint is still true (never reset), and the second send should NOT
        // re-trigger because the guard `!showUpgradeHint` prevents it.
        XCTAssertFalse(secondCallback, "onUpgradeHintTriggered should not fire again once hint is already shown")
    }

    func test_upgradeHint_doesNotTriggerWhenResponseEmpty() async {
        let originalConfig = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfig }

        BaseChatConfiguration.shared.features = BaseChatConfiguration.Features(showUpgradeHint: true)

        let mock = MockInferenceBackend()
        mock.tokensToYield = []  // Empty response
        let vm = makeVM(backend: mock, name: "Apple")

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertFalse(vm.showUpgradeHint, "showUpgradeHint should remain false when response is empty")
    }

    // MARK: - 3. Context Trimming During Generation

    func test_contextTrimming_reducesPromptForLowContextWindow() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["OK"]
        // Use requiresPromptTemplate so the full formatted prompt is captured.
        mock.capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 100,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false
        )
        let vm = makeVM(backend: mock)
        // Set a very small context window.
        vm.contextMaxTokens = 100

        // Add many long messages directly to the messages array.
        let sessionID = vm.activeSession!.id
        let longContent = String(repeating: "word ", count: 200) // ~1000 chars = ~250 tokens
        for i in 0..<10 {
            let role: MessageRole = i.isMultiple(of: 2) ? .user : .assistant
            let msg = ChatMessage(role: role, content: longContent, sessionID: sessionID)
            vm.messages.append(msg)
        }

        // Now send a new message.
        vm.inputText = "Short question"
        await vm.sendMessage()

        // The prompt passed to the backend should be shorter than if all messages
        // had been included. With 10 prior messages of ~250 tokens each plus the
        // new user message, the full conversation is ~2500 tokens. With a 100 token
        // context window, trimming should drop most of them.
        let capturedPrompt = mock.lastPrompt ?? ""
        let fullConversationLength = longContent.count * 10 + "Short question".count
        XCTAssertLessThan(
            capturedPrompt.count, fullConversationLength,
            "Prompt should be trimmed to fit within context window (prompt length: \(capturedPrompt.count), full: \(fullConversationLength))"
        )
    }

    // MARK: - 4. Empty Response Cleanup

    func test_emptyResponse_removesAssistantPlaceholder() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = []  // Zero tokens
        let vm = makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        // The user message should remain; the empty assistant message should be removed.
        XCTAssertEqual(vm.messages.count, 1, "Only the user message should remain when assistant produces no tokens")
        XCTAssertEqual(vm.messages.first?.role, .user, "Remaining message should be the user message")
    }

    func test_nonEmptyResponse_persistsAssistantMessage() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hi"]
        let vm = makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Both user and assistant messages should be present")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].content, "Hi")
    }

    // MARK: - 5. isGenerating Flag Transitions

    func test_isGenerating_falseAfterSuccessfulGeneration() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Done"]
        let vm = makeVM(backend: mock)

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false before generation")

        vm.inputText = "Go"
        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after successful generation")
    }

    func test_isGenerating_falseAfterGenerationError() async {
        let mock = MockInferenceBackend()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("Boom")
        let vm = makeVM(backend: mock)

        vm.inputText = "Go"
        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after generation error")
    }

    func test_isGenerating_falseAfterStreamError() async {
        let errorBackend = StreamErrorMockBackend()
        let vm = makeVM(rawBackend: errorBackend)

        vm.inputText = "Go"
        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stream error")
    }

    // MARK: - 6. generationDidFinish Cleans Up Service State

    func test_generationDidFinish_setsServiceIsGeneratingFalse() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Token"]
        let vm = makeVM(backend: mock)

        vm.inputText = "Test"
        await vm.sendMessage()

        XCTAssertFalse(
            vm.inferenceService.isGenerating,
            "InferenceService.isGenerating should be false after generation completes (generationDidFinish called)"
        )
    }

    func test_generationDidFinish_calledEvenOnError() async {
        let mock = MockInferenceBackend()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("fail")
        let vm = makeVM(backend: mock)

        vm.inputText = "Test"
        await vm.sendMessage()

        XCTAssertFalse(
            vm.inferenceService.isGenerating,
            "InferenceService.isGenerating should be false even after generation error"
        )
    }

    // MARK: - 7. Error During Generation Sets errorMessage

    func test_generationStartError_setsErrorMessage() async {
        let mock = MockInferenceBackend()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("backend exploded")
        let vm = makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when generation throws")
        XCTAssertTrue(
            vm.errorMessage?.contains("Generation failed") == true,
            "Error should mention 'Generation failed', got: \(vm.errorMessage ?? "nil")"
        )
    }

    func test_streamError_setsErrorMessage() async {
        let errorBackend = StreamErrorMockBackend()
        let vm = makeVM(rawBackend: errorBackend)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when stream throws")
        XCTAssertTrue(
            vm.errorMessage?.contains("stream boom") == true,
            "Error should contain the stream error description, got: \(vm.errorMessage ?? "nil")"
        )
    }
}

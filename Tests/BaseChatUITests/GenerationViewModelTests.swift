import XCTest
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

@MainActor
final class ChatViewModelTests: XCTestCase {

    // MARK: - Helpers

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    /// Convenience to build a view model with controllable device memory.
    /// Uses a default InferenceService (no backend loaded).
    private func makeViewModel(ramGB: UInt64 = 16) -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            deviceCapability: DeviceCapabilityService(physicalMemory: ramGB * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
    }

    /// Convenience to build a view model with a mock backend pre-loaded.
    private func makeViewModelWithMock(
        ramGB: UInt64 = 16,
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: ramGB * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        // Set an active session so sendMessage/regenerate/edit don't bail out.
        vm.activeSession = ChatSession(title: "Test Session")
        return (vm, mock)
    }

    /// The models directory used by a default `ModelStorageService`.
    private var modelsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Models", isDirectory: true)
    }

    /// Creates a fake .gguf file in the models directory and returns its URL.
    @discardableResult
    private func createFakeGGUF(named fileName: String, sizeBytes: Int = 1024) throws -> URL {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let fileURL = modelsDirectory.appendingPathComponent(fileName)
        let data = Data(repeating: 0, count: sizeBytes)
        try data.write(to: fileURL)
        return fileURL
    }

    /// Removes a file at the given URL if it exists.
    private func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes all .gguf files from the models directory created during the test.
    private var createdFiles: [URL] = []

    override func tearDown() {
        super.tearDown()
        for url in createdFiles {
            removeFile(at: url)
        }
        createdFiles.removeAll()
    }

    // MARK: - test_init_defaultState

    func test_init_defaultState() {
        let vm = makeViewModel()

        XCTAssertTrue(vm.availableModels.isEmpty, "availableModels should be empty on init")
        XCTAssertNil(vm.selectedModel, "selectedModel should be nil on init")
        XCTAssertEqual(vm.inputText, "", "inputText should be empty on init")
        XCTAssertTrue(vm.messages.isEmpty, "messages should be empty on init")
        XCTAssertFalse(vm.isLoading, "isLoading should be false on init")
        XCTAssertNil(vm.errorMessage, "errorMessage should be nil on init")
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false on init")
        XCTAssertFalse(vm.isModelLoaded, "isModelLoaded should be false on init")
    }

    // MARK: - test_refreshModels_populatesAvailableModels

    func test_refreshModels_populatesAvailableModels() throws {
        let url = try createFakeGGUF(named: "test-refresh-model.gguf")
        createdFiles.append(url)

        let vm = makeViewModel()
        vm.refreshModels()

        XCTAssertFalse(vm.availableModels.isEmpty, "availableModels should contain discovered models")
        XCTAssertTrue(
            vm.availableModels.contains(where: { $0.fileName == "test-refresh-model.gguf" }),
            "availableModels should include the test model file"
        )
    }

    // MARK: - test_refreshModels_clearsStaleSelection

    func test_refreshModels_clearsStaleSelection() throws {
        let url = try createFakeGGUF(named: "test-stale-model.gguf")
        createdFiles.append(url)

        let vm = makeViewModel()
        vm.refreshModels()

        // Select the discovered model.
        let model = vm.availableModels.first { $0.fileName == "test-stale-model.gguf" }
        XCTAssertNotNil(model, "Should have discovered the test model")
        vm.selectedModel = model

        // Delete the file and refresh.
        removeFile(at: url)
        vm.refreshModels()

        XCTAssertNil(vm.selectedModel, "selectedModel should be cleared when file no longer exists")
    }

    // MARK: - test_loadSelectedModel_noSelection_setsError

    func test_loadSelectedModel_noSelection_setsError() async {
        let vm = makeViewModel()
        XCTAssertNil(vm.selectedModel)

        await vm.loadSelectedModel()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when no model is selected")
        XCTAssertEqual(vm.errorMessage, "No model selected.")
    }

    // MARK: - test_loadSelectedModel_modelTooLarge_setsError

    func test_loadSelectedModel_modelTooLarge_setsError() async {
        // 4 GB device with a 4 GB model.
        // Budget: 4 * 0.70 = 2.8 GB. Model + KV: 4 * 1.20 = 4.8 GB. Should fail.
        let vm = makeViewModel(ramGB: 4)

        let largeModel = ModelInfo(
            name: "huge-model",
            fileName: "huge-model.gguf",
            url: URL(fileURLWithPath: "/tmp/huge-model.gguf"),
            fileSize: 4 * oneGB,
            modelType: .gguf
        )
        vm.selectedModel = largeModel

        await vm.loadSelectedModel()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when model is too large")
        XCTAssertTrue(
            vm.errorMessage?.contains("too large") == true,
            "Error should mention the model being too large, got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - test_sendMessage_emptyInput_doesNothing

    func test_sendMessage_emptyInput_doesNothing() async {
        let vm = makeViewModel()
        vm.inputText = ""

        await vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty, "messages should remain empty when input is empty")
        XCTAssertNil(vm.errorMessage, "No error should be set for empty input")
    }

    // MARK: - test_sendMessage_noModelLoaded_setsError

    func test_sendMessage_noModelLoaded_setsError() async {
        let vm = makeViewModel()
        vm.activeSession = ChatSession(title: "Test")
        vm.inputText = "Tell me a story"

        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when no model is loaded")
        XCTAssertTrue(
            vm.errorMessage?.contains("No model loaded") == true,
            "Error should mention no model loaded, got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - test_sendMessage_addsUserMessage

    func test_sendMessage_addsUserMessage() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello, assistant!"

        await vm.sendMessage()

        // Should have a user message and an assistant message.
        let userMessages = vm.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1, "Should have one user message")
        XCTAssertEqual(userMessages.first?.content, "Hello, assistant!", "User message content should match input")

        // Input should be cleared after sending.
        XCTAssertEqual(vm.inputText, "", "inputText should be cleared after sending")
    }

    // MARK: - test_clearChat_removesAllMessages

    func test_clearChat_removesAllMessages() async {
        let (vm, _) = makeViewModelWithMock()

        // Send a message to populate the chat.
        vm.inputText = "First message"
        await vm.sendMessage()

        XCTAssertFalse(vm.messages.isEmpty, "Should have messages after sending")

        vm.clearChat()

        XCTAssertTrue(vm.messages.isEmpty, "messages should be empty after clearChat")
    }

    // MARK: - test_autoSelectFirstRunModel_selectsFoundation

    func test_autoSelectFirstRunModel_selectsFoundation() {
        // Clear the flag so autoSelectFirstRunModel treats this as first launch.
        UserDefaults.standard.removeObject(forKey: "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch")

        let vm = makeViewModel()

        // Manually add a foundation model to available models
        // (refreshModels would check actual availability which may not be present in tests).
        // Instead, we test the logic path: if foundation is in availableModels, it gets selected.

        // First, refresh to populate (may or may not include Foundation depending on OS).
        vm.refreshModels()

        // If Foundation is available in the list, autoSelect should pick it.
        let hasFoundation = vm.availableModels.contains(where: { $0.modelType == .foundation })

        vm.autoSelectFirstRunModel()

        if hasFoundation {
            XCTAssertNotNil(vm.selectedModel, "Should have auto-selected a model")
            XCTAssertEqual(vm.selectedModel?.modelType, .foundation,
                          "Should have auto-selected the foundation model")
        } else {
            // Foundation not available on this OS -- autoSelect won't find it.
            // Verify it didn't crash and the flag was set.
            XCTAssertTrue(UserDefaults.standard.bool(forKey: "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch"),
                         "Flag should be set even if no foundation model available")
        }

        // Clean up.
        UserDefaults.standard.removeObject(forKey: "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch")
    }

    // MARK: - test_autoSelectFirstRunModel_doesNotRepeat

    func test_autoSelectFirstRunModel_doesNotRepeat() {
        // Set the flag as if first launch already happened.
        UserDefaults.standard.set(true, forKey: "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch")

        let vm = makeViewModel()
        vm.refreshModels()
        vm.autoSelectFirstRunModel()

        // Should NOT auto-select because the flag is already set.
        XCTAssertNil(vm.selectedModel, "Should not auto-select on subsequent launches")

        // Clean up.
        UserDefaults.standard.removeObject(forKey: "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch")
    }

    // MARK: - test_handleMemoryPressure_nominal_doesNotSetError

    func test_handleMemoryPressure_nominal_doesNotSetError() {
        let vm = makeViewModel()

        vm.handleMemoryPressure()

        // On the very first call, lastPressureLevel == .nominal and pressureLevel == .nominal,
        // so the guard (level != lastPressureLevel) prevents any action.
        XCTAssertNil(vm.errorMessage,
                     "handleMemoryPressure at nominal should not set an error")
    }

    // MARK: - test_deviceDescription_returnsNonEmpty

    func test_deviceDescription_returnsNonEmpty() {
        let vm = makeViewModel(ramGB: 16)

        XCTAssertFalse(vm.deviceDescription.isEmpty, "deviceDescription should not be empty")
        XCTAssertTrue(
            vm.deviceDescription.contains("16 GB RAM"),
            "deviceDescription should contain RAM info, got: \(vm.deviceDescription)"
        )
    }

    // MARK: - test_recommendedSize_returnsValidRecommendation

    func test_recommendedSize_returnsValidRecommendation() {
        let vm = makeViewModel(ramGB: 8)

        let recommendation = vm.recommendedSize
        XCTAssertTrue(
            ModelSizeRecommendation.allCases.contains(recommendation),
            "recommendedSize should return a valid ModelSizeRecommendation"
        )
        // 8 GB should recommend .medium.
        XCTAssertEqual(recommendation, .medium, "8 GB device should recommend medium models")
    }

    // MARK: - test_modelsDirectoryPath_returnsNonEmpty

    func test_modelsDirectoryPath_returnsNonEmpty() {
        let vm = makeViewModel()

        XCTAssertFalse(vm.modelsDirectoryPath.isEmpty, "modelsDirectoryPath should not be empty")
        XCTAssertTrue(
            vm.modelsDirectoryPath.contains("Models"),
            "modelsDirectoryPath should contain 'Models', got: \(vm.modelsDirectoryPath)"
        )
    }

    // MARK: - test_backendCapabilities_nilWhenNoModel

    func test_backendCapabilities_nilWhenNoModel() {
        let vm = makeViewModel()
        XCTAssertNil(vm.backendCapabilities, "backendCapabilities should be nil when no model loaded")
    }

    // MARK: - test_backendCapabilities_availableWithMock

    func test_backendCapabilities_availableWithMock() {
        let (vm, _) = makeViewModelWithMock()
        XCTAssertNotNil(vm.backendCapabilities, "backendCapabilities should be available when model is loaded")
    }

    // MARK: - Generation Streaming Flow

    func test_sendMessage_streamsTokensIntoAssistantMessage() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " world"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Say hello"

        await vm.sendMessage()

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Should have one assistant message")
        XCTAssertEqual(
            assistantMessages.first?.content, "Hello world",
            "Assistant message should contain streamed tokens concatenated"
        )
    }

    func test_sendMessage_createsUserAndAssistantMessages() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Tell me a story"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Should have exactly 2 messages (user + assistant)")
        XCTAssertEqual(vm.messages[0].role, .user, "First message should be from user")
        XCTAssertEqual(vm.messages[0].content, "Tell me a story", "User message content should match input")
        XCTAssertEqual(vm.messages[1].role, .assistant, "Second message should be from assistant")
    }

    // MARK: - Regenerate

    func test_regenerateLastResponse_removesAndRecreatesAssistant() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["First", " response"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Should have user + assistant after send")
        XCTAssertEqual(vm.messages[1].content, "First response")

        // Change the mock tokens for the regeneration.
        mock.tokensToYield = ["Regenerated", " response"]

        await vm.regenerateLastResponse()

        XCTAssertEqual(vm.messages.count, 2, "Should still have exactly 2 messages after regenerate")
        XCTAssertEqual(vm.messages[0].role, .user, "First message should still be from user")
        XCTAssertEqual(vm.messages[1].role, .assistant, "Second message should still be from assistant")
        XCTAssertEqual(
            vm.messages[1].content, "Regenerated response",
            "Assistant message should have new regenerated content"
        )
    }

    func test_regenerateLastResponse_noAssistantMessage_doesNothing() async {
        let (vm, _) = makeViewModelWithMock()

        // Messages is empty — regenerate should be a no-op.
        XCTAssertTrue(vm.messages.isEmpty, "Precondition: messages should be empty")

        await vm.regenerateLastResponse()

        XCTAssertTrue(vm.messages.isEmpty, "Messages should remain empty after regenerate with no assistant")
    }

    // MARK: - Stop Generation

    func test_stopGeneration_setsIsGeneratingFalse() async {
        let (vm, _) = makeViewModelWithMock()

        // Verify isGenerating is false before and after stopGeneration.
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false before any generation")

        vm.stopGeneration()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stopGeneration")
    }

    func test_stopGeneration_callsInferenceServiceStop() {
        let mock = MockInferenceBackend()
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.stopGeneration()

        XCTAssertEqual(mock.stopCallCount, 1, "stopGeneration should call backend's stopGeneration")
    }

    // MARK: - Edit Message

    func test_editMessage_updatesContentAndRegenerates() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Original", " reply"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Original question"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Should have user + assistant")
        XCTAssertEqual(vm.messages[0].content, "Original question")
        XCTAssertEqual(vm.messages[1].content, "Original reply")

        // Edit the user message with new content.
        mock.tokensToYield = ["New", " reply"]
        let userMessage = vm.messages[0]

        await vm.editMessage(userMessage, newContent: "Edited question")

        XCTAssertEqual(vm.messages[0].content, "Edited question", "User message should be updated")
        XCTAssertEqual(vm.messages.count, 2, "Should still have 2 messages after edit + regenerate")
        XCTAssertEqual(vm.messages[1].role, .assistant, "Second message should be assistant")
        XCTAssertEqual(
            vm.messages[1].content, "New reply",
            "Assistant message should be regenerated with new tokens"
        )
    }

    func test_editMessage_nonExistentMessage_doesNothing() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello"
        await vm.sendMessage()

        let originalCount = vm.messages.count
        let fakeMessage = ChatMessage(role: .user, content: "Fake", sessionID: UUID())

        await vm.editMessage(fakeMessage, newContent: "Edited")

        XCTAssertEqual(vm.messages.count, originalCount, "Messages should not change when editing a non-existent message")
    }

    // MARK: - Auto-template Detection on Model Load

    func test_loadSelectedModel_autoDetectsPromptTemplate() async {
        let (vm, _) = makeViewModelWithMock()

        // Create a model with a detected prompt template.
        let model = ModelInfo(
            name: "test-llama",
            fileName: "test-llama.gguf",
            url: URL(fileURLWithPath: "/tmp/test-llama.gguf"),
            fileSize: 1024,
            modelType: .gguf,
            detectedPromptTemplate: .llama3
        )
        vm.selectedModel = model

        // The actual loadModel will fail because the file doesn't exist,
        // but the template should be set before the load attempt.
        await vm.loadSelectedModel()

        XCTAssertEqual(
            vm.selectedPromptTemplate, .llama3,
            "selectedPromptTemplate should be auto-detected from model metadata"
        )
    }

    // MARK: - System Prompt in Generation

    func test_sendMessage_includesSystemPrompt() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Response"]
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.systemPrompt = "You are a helpful storytelling assistant."
        vm.inputText = "Tell me a story"

        await vm.sendMessage()

        // The mock backend captures lastSystemPrompt. Since MockInferenceBackend
        // has supportsSystemPrompt: true and requiresPromptTemplate: false,
        // the InferenceService passes the system prompt through to the backend.
        XCTAssertEqual(
            mock.lastSystemPrompt, "You are a helpful storytelling assistant.",
            "Backend should receive the system prompt"
        )
    }

    func test_sendMessage_nilSystemPromptWhenEmpty() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Response"]
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.systemPrompt = ""
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertNil(
            mock.lastSystemPrompt,
            "Backend should receive nil system prompt when systemPrompt is empty"
        )
    }

    // MARK: - Generation Error Handling

    func test_sendMessage_generationError_setsErrorMessage() async {
        let mock = MockInferenceBackend()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("Test error")
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when generation fails")
        XCTAssertTrue(
            vm.errorMessage?.contains("Generation failed") == true,
            "Error should mention generation failure, got: \(vm.errorMessage ?? "nil")"
        )
    }

    func test_sendMessage_clearsInputAfterSending() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello there"

        await vm.sendMessage()

        XCTAssertEqual(vm.inputText, "", "inputText should be cleared after sending")
    }

    func test_sendMessage_isGeneratingFalseAfterCompletion() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after generation completes")
    }

    // MARK: - Multiple Messages

    func test_sendMessage_multipleMessages_accumulatesHistory() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Reply", " 1"]
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.inputText = "First message"
        await vm.sendMessage()

        mock.tokensToYield = ["Reply", " 2"]
        vm.inputText = "Second message"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 4, "Should have 4 messages (2 user + 2 assistant)")
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].content, "First message")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].content, "Reply 1")
        XCTAssertEqual(vm.messages[2].role, .user)
        XCTAssertEqual(vm.messages[2].content, "Second message")
        XCTAssertEqual(vm.messages[3].role, .assistant)
        XCTAssertEqual(vm.messages[3].content, "Reply 2")
    }

    // MARK: - Clear Chat After Messages

    func test_clearChat_afterMultipleMessages_removesAll() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Reply"]
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.inputText = "Msg 1"
        await vm.sendMessage()
        vm.inputText = "Msg 2"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 4, "Precondition: should have 4 messages")

        vm.clearChat()

        XCTAssertTrue(vm.messages.isEmpty, "All messages should be cleared")
    }
}

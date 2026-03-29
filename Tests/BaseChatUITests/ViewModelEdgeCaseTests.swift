import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

@MainActor
final class ViewModelEdgeCaseTests: XCTestCase {

    // MARK: - Helpers

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeViewModel(ramGB: UInt64 = 16) -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            deviceCapability: DeviceCapabilityService(physicalMemory: ramGB * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
    }

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
        return (vm, mock)
    }

    /// Creates a view model with an in-memory SwiftData container configured.
    private func makeViewModelWithPersistence(
        mock: MockInferenceBackend = MockInferenceBackend()
    ) throws -> (ChatViewModel, MockInferenceBackend, ModelContainer) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        vm.configure(modelContext: context)
        return (vm, mock, container)
    }

    // MARK: - saveSettingsToSession

    func test_saveSettingsToSession_updatesSessionProperties() throws {
        let (vm, _, container) = try makeViewModelWithPersistence()
        let context = ModelContext(container)

        let session = ChatSession(title: "Settings Test")
        context.insert(session)
        try context.save()

        vm.activeSession = session
        vm.temperature = 0.3
        vm.topP = 0.8
        vm.repeatPenalty = 1.5
        vm.systemPrompt = "Be concise."

        vm.saveSettingsToSession()

        XCTAssertEqual(session.temperature!, 0.3, accuracy: 0.001,
                       "Session temperature should match view model value")
        XCTAssertEqual(session.topP!, 0.8, accuracy: 0.001,
                       "Session topP should match view model value")
        XCTAssertEqual(session.repeatPenalty!, 1.5, accuracy: 0.001,
                       "Session repeatPenalty should match view model value")
        XCTAssertEqual(session.systemPrompt, "Be concise.",
                       "Session systemPrompt should match view model value")
    }

    func test_saveSettingsToSession_noActiveSession_isNoop() throws {
        let (vm, _, _) = try makeViewModelWithPersistence()

        // No active session — should not crash.
        vm.temperature = 0.5
        vm.saveSettingsToSession()

        XCTAssertNil(vm.activeSession, "activeSession should remain nil")
    }

    // MARK: - switchToSession

    func test_switchToSession_loadsSessionSettings() throws {
        let (vm, _, container) = try makeViewModelWithPersistence()
        let context = ModelContext(container)

        let sessionA = ChatSession(title: "Session A")
        sessionA.temperature = 0.2
        sessionA.topP = 0.5
        sessionA.repeatPenalty = 1.0
        sessionA.systemPrompt = "Prompt A"
        context.insert(sessionA)

        let sessionB = ChatSession(title: "Session B")
        sessionB.temperature = 0.9
        sessionB.topP = 0.95
        sessionB.repeatPenalty = 1.3
        sessionB.systemPrompt = "Prompt B"
        context.insert(sessionB)
        try context.save()

        vm.switchToSession(sessionA)
        XCTAssertEqual(vm.temperature, 0.2, accuracy: 0.001)
        XCTAssertEqual(vm.systemPrompt, "Prompt A")

        vm.switchToSession(sessionB)
        XCTAssertEqual(vm.temperature, 0.9, accuracy: 0.001,
                       "Temperature should reflect session B after switch")
        XCTAssertEqual(vm.topP, 0.95, accuracy: 0.001,
                       "topP should reflect session B after switch")
        XCTAssertEqual(vm.repeatPenalty, 1.3, accuracy: 0.001,
                       "repeatPenalty should reflect session B after switch")
        XCTAssertEqual(vm.systemPrompt, "Prompt B",
                       "systemPrompt should reflect session B after switch")
    }

    func test_switchToSession_clearsMessages() async throws {
        let (vm, mock, container) = try makeViewModelWithPersistence(mock: MockInferenceBackend())
        let context = ModelContext(container)

        let sessionA = ChatSession(title: "Session A")
        context.insert(sessionA)
        try context.save()

        vm.activeSession = sessionA
        vm.inputText = "Hello"
        await vm.sendMessage()

        let countBeforeSwitch = vm.messages.count
        XCTAssertGreaterThan(countBeforeSwitch, 0,
                             "Should have messages before switching")

        let sessionB = ChatSession(title: "Session B")
        context.insert(sessionB)
        try context.save()

        vm.switchToSession(sessionB)

        // Session B has no persisted messages, so messages should be empty.
        XCTAssertTrue(vm.messages.isEmpty,
                      "Messages should be empty after switching to a session with no messages")
    }

    func test_switchToSession_usesDefaultsForNilSettings() throws {
        let (vm, _, container) = try makeViewModelWithPersistence()
        let context = ModelContext(container)

        let session = ChatSession(title: "Defaults Session")
        // Leave temperature, topP, repeatPenalty as nil (defaults)
        context.insert(session)
        try context.save()

        // Set non-default values on VM first
        vm.temperature = 0.1
        vm.topP = 0.1
        vm.repeatPenalty = 2.0

        vm.switchToSession(session)

        XCTAssertEqual(vm.temperature, 0.7, accuracy: 0.001,
                       "Should fall back to 0.7 default when session temperature is nil")
        XCTAssertEqual(vm.topP, 0.9, accuracy: 0.001,
                       "Should fall back to 0.9 default when session topP is nil")
        XCTAssertEqual(vm.repeatPenalty, 1.1, accuracy: 0.001,
                       "Should fall back to 1.1 default when session repeatPenalty is nil")
    }

    // MARK: - editMessage on assistant message

    func test_editMessage_assistantMessage_updatesContentButDoesNotRegenerate() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Original", " reply"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.activeSession = ChatSession(title: "Test")
        vm.inputText = "Question"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2)
        let assistantMessage = vm.messages[1]
        XCTAssertEqual(assistantMessage.role, .assistant)

        let generateCountBefore = mock.generateCallCount

        await vm.editMessage(assistantMessage, newContent: "Edited assistant text")

        // Editing an assistant message should update its content...
        XCTAssertEqual(assistantMessage.content, "Edited assistant text",
                       "Assistant message content should be updated")
        // ...but should NOT trigger regeneration (only user edits do that).
        XCTAssertEqual(mock.generateCallCount, generateCountBefore,
                       "Editing an assistant message should not trigger regeneration")
        // Message count should remain the same (no messages after the assistant to remove).
        XCTAssertEqual(vm.messages.count, 2,
                       "Message count should remain unchanged after editing the last assistant message")
    }

    // MARK: - editMessage with empty content

    func test_editMessage_emptyContent_updatesMessageToEmpty() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Reply"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.activeSession = ChatSession(title: "Test")
        vm.inputText = "Hello"

        await vm.sendMessage()

        let userMessage = vm.messages[0]
        XCTAssertEqual(userMessage.role, .user)

        // Edit with empty content — the method does not guard against this.
        mock.tokensToYield = ["New", " reply"]
        await vm.editMessage(userMessage, newContent: "")

        XCTAssertEqual(userMessage.content, "",
                       "User message content should be set to empty string")
        // Since it was a user message edit, regeneration should still occur.
        XCTAssertEqual(vm.messages.count, 2,
                       "Should still have user + regenerated assistant message")
    }

    // MARK: - sendMessage whitespace-only input

    func test_sendMessage_whitespaceOnlyInput_isNoop() async {
        let (vm, mock) = makeViewModelWithMock()
        vm.activeSession = ChatSession(title: "Test")
        vm.inputText = "   \n  "

        await vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty,
                      "Whitespace-only input should not produce any messages")
        XCTAssertEqual(mock.generateCallCount, 0,
                       "No generation should be triggered for whitespace-only input")
    }

    func test_sendMessage_tabAndNewlineInput_isNoop() async {
        let (vm, mock) = makeViewModelWithMock()
        vm.activeSession = ChatSession(title: "Test")
        vm.inputText = "\t\n\r\n  \t"

        await vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty,
                      "Tab/newline-only input should not produce any messages")
        XCTAssertEqual(mock.generateCallCount, 0,
                       "No generation should be triggered for whitespace input")
    }

    // MARK: - sendMessage clears errorMessage

    func test_sendMessage_clearsExistingErrorMessage() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["OK"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.activeSession = ChatSession(title: "Test")

        vm.errorMessage = "Previous error that should be cleared"
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertNil(vm.errorMessage,
                     "errorMessage should be cleared after a successful sendMessage")
    }

    func test_sendMessage_noSession_setsErrorMessage() async {
        let (vm, _) = makeViewModelWithMock()
        // No active session
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage,
                        "errorMessage should be set when no active session exists")
        XCTAssertTrue(vm.errorMessage?.contains("No active session") == true,
                      "Error should mention no active session, got: \(vm.errorMessage ?? "nil")")
    }

    // MARK: - exportChat formats

    func test_exportChat_markdownFormat_returnsNonEmptyOutput() {
        let (vm, _) = makeViewModelWithMock()
        vm.activeSession = ChatSession(title: "Export Test")

        // Manually add messages to test export without triggering generation.
        let sessionID = vm.activeSession!.id
        vm.messages = [
            ChatMessage(role: .user, content: "What is 2+2?", sessionID: sessionID),
            ChatMessage(role: .assistant, content: "4", sessionID: sessionID)
        ]

        let markdown = vm.exportChat(format: .markdown)

        XCTAssertFalse(markdown.isEmpty, "Markdown export should not be empty")
        XCTAssertTrue(markdown.contains("# Export Test"),
                      "Markdown export should contain session title as heading")
        XCTAssertTrue(markdown.contains("What is 2+2?"),
                      "Markdown export should contain user message content")
        XCTAssertTrue(markdown.contains("4"),
                      "Markdown export should contain assistant message content")
        XCTAssertTrue(markdown.contains("**User:**"),
                      "Markdown export should format user role in bold")
        XCTAssertTrue(markdown.contains("**Assistant:**"),
                      "Markdown export should format assistant role in bold")
    }

    func test_exportChat_plainTextFormat_returnsNonEmptyOutput() {
        let (vm, _) = makeViewModelWithMock()
        vm.activeSession = ChatSession(title: "Plain Export")

        let sessionID = vm.activeSession!.id
        vm.messages = [
            ChatMessage(role: .user, content: "Hello", sessionID: sessionID),
            ChatMessage(role: .assistant, content: "Hi there", sessionID: sessionID)
        ]

        let plainText = vm.exportChat(format: .plainText)

        XCTAssertFalse(plainText.isEmpty, "Plain text export should not be empty")
        XCTAssertTrue(plainText.contains("Plain Export"),
                      "Plain text export should contain session title")
        XCTAssertTrue(plainText.contains("User: Hello"),
                      "Plain text export should contain user message")
        XCTAssertTrue(plainText.contains("Assistant: Hi there"),
                      "Plain text export should contain assistant message")
    }

    func test_exportChat_emptyMessages_returnsHeaderOnly() {
        let (vm, _) = makeViewModelWithMock()
        vm.activeSession = ChatSession(title: "Empty Chat")
        vm.messages = []

        let markdown = vm.exportChat(format: .markdown)

        XCTAssertFalse(markdown.isEmpty, "Export of empty chat should still produce a header")
        XCTAssertTrue(markdown.contains("# Empty Chat"),
                      "Export should contain the session title even with no messages")
    }
}

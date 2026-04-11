@preconcurrency import XCTest
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

@MainActor
final class ChatViewModelMacroExpansionTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeVM(backend: MockInferenceBackend) -> ChatViewModel {
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSessionRecord(title: "Test")
        return vm
    }

    // MARK: - Macro expansion on system prompt

    func test_systemPrompt_macrosExpanded_beforeGeneration() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "You are talking to {{user}}."
        vm.macroContext = MacroContext(userName: "Alice")

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "You are talking to Alice.",
            "System prompt should have {{user}} expanded before reaching the backend"
        )
    }

    // MARK: - Macro expansion disabled

    func test_systemPrompt_passedThrough_whenExpansionDisabled() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "You are talking to {{user}}."
        vm.macroContext = MacroContext(userName: "Alice")
        vm.macroExpansionEnabled = false

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "You are talking to {{user}}.",
            "System prompt should pass through unchanged when macro expansion is disabled"
        )
    }

    // MARK: - Auto-populated message references

    func test_lastMessage_autoPopulated_fromHistory() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "Last said: {{lastMessage}}"

        // Seed a prior user message in the history
        let sessionID = vm.activeSession!.id
        vm.messages = [
            ChatMessageRecord(role: .user, content: "First question", sessionID: sessionID),
            ChatMessageRecord(role: .assistant, content: "First answer", sessionID: sessionID),
        ]

        vm.inputText = "Second question"
        await vm.sendMessage()

        // The lastMessage should be auto-populated from history (the user's "Second question"
        // was appended before generation, so it should be the most recent non-assistant message
        // or the most recent of either role)
        let systemPromptSent = mock.lastSystemPrompt ?? ""
        XCTAssertFalse(
            systemPromptSent.contains("{{lastMessage}}"),
            "{{lastMessage}} should have been expanded, got: \(systemPromptSent)"
        )
    }

    // MARK: - Date macros expand without context

    func test_dateMacros_expandAutomatically() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "Today is {{date}}."

        vm.inputText = "Hi"
        await vm.sendMessage()

        let systemPromptSent = mock.lastSystemPrompt ?? ""
        XCTAssertFalse(
            systemPromptSent.contains("{{date}}"),
            "{{date}} should have been expanded, got: \(systemPromptSent)"
        )
    }
}

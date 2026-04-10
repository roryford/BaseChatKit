@preconcurrency import XCTest
@testable import BaseChatUI
@testable import BaseChatCore
import BaseChatTestSupport

@MainActor
final class ChatViewModelSystemPromptContextTests: XCTestCase {

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

    // MARK: - Substitution works

    func test_systemPromptContext_substitutesTokens_beforeReachingBackend() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "The assistant greets {{name}}."
        vm.systemPromptContext = ["name": "Alice"]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "The assistant greets Alice.",
            "systemPromptContext should substitute {{name}} before the prompt reaches the backend"
        )
    }

    // MARK: - Empty dict is a no-op

    func test_systemPromptContext_emptyDict_leavesMacroExpanderBehaviorUnchanged() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "You are talking to {{user}}."
        vm.macroContext = MacroContext(userName: "Alice")
        vm.systemPromptContext = [:]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "You are talking to Alice.",
            "An empty systemPromptContext must not alter MacroExpander's output"
        )
    }

    // MARK: - MacroExpander wins on collision (ordering)

    func test_macroExpanderWins_onCollision_withSystemPromptContext() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "Hello {{user}}."
        vm.macroContext = MacroContext(userName: "Bob")
        vm.systemPromptContext = ["user": "Charlie"]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Hello Bob.",
            "MacroExpander runs first, so {{user}} must resolve to the macroContext value (Bob), not the systemPromptContext value (Charlie)"
        )
    }

    // MARK: - Additional coverage: tokens untouched by MacroExpander are filled by systemPromptContext

    func test_systemPromptContext_fillsTokens_notHandledByMacroExpander() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "You are {{persona}} talking to {{user}}."
        vm.macroContext = MacroContext(userName: "Alice")
        vm.systemPromptContext = ["persona": "a helpful guide"]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "You are a helpful guide talking to Alice.",
            "systemPromptContext should substitute tokens that MacroExpander did not handle, while MacroExpander handles its own tokens"
        )
    }
}

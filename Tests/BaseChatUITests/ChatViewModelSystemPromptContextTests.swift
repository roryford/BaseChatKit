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

    // MARK: - Missing token passes through verbatim

    func test_systemPromptContext_missingKey_leavesTokenVerbatim() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "Hello {{name}}, your role is {{role}}."
        vm.systemPromptContext = ["name": "Alice"] // role is intentionally absent

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Hello Alice, your role is {{role}}.",
            "Tokens whose key is missing from the dict must pass through unchanged so callers can spot them"
        )
    }

    // MARK: - Multiple occurrences of the same token

    func test_systemPromptContext_replacesAllOccurrencesOfSameToken() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "{{name}} likes {{name}}'s coffee. {{name}} drinks it daily."
        vm.systemPromptContext = ["name": "Alice"]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Alice likes Alice's coffee. Alice drinks it daily.",
            "Every occurrence of the same {{key}} should be replaced, not just the first"
        )
    }

    // MARK: - Substitution is non-recursive

    func test_systemPromptContext_doesNotRecursivelyExpandValues() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "Hello {{first}}."
        // If substitution were recursive, "{{first}}" would expand to
        // "{{second}}" then to "Bob". Since we guarantee non-recursion, the
        // literal "{{second}}" must reach the backend.
        vm.systemPromptContext = ["first": "{{second}}", "second": "Bob"]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Hello {{second}}.",
            "systemPromptContext must not recursively re-expand values, regardless of dict iteration order"
        )
    }

    // MARK: - Substitution runs even when macroExpansionEnabled is false

    func test_systemPromptContext_runs_whenMacroExpansionDisabled() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "Hello {{name}}."
        vm.systemPromptContext = ["name": "Alice"]
        vm.macroExpansionEnabled = false

        vm.inputText = "Hi"
        await vm.sendMessage()

        // The full MacroExpander pass is skipped, but the dict-based pass still runs.
        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Hello Alice.",
            "systemPromptContext substitution must not be gated on macroExpansionEnabled"
        )
    }

    // MARK: - Empty string value substitutes correctly

    func test_systemPromptContext_emptyStringValue_substitutesAsEmpty() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "Persona: {{persona}}|end"
        vm.systemPromptContext = ["persona": ""]

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Persona: |end",
            "An empty-string value should erase the token, not leave it as a literal"
        )
    }

    // MARK: - Mid-conversation mutation between sends

    func test_systemPromptContext_mutationBetweenSends_appliesToSecondPrompt() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok", "ok"]
        let vm = makeVM(backend: mock)
        vm.systemPrompt = "Talking to {{name}}."
        vm.systemPromptContext = ["name": "Alice"]

        vm.inputText = "Hi"
        await vm.sendMessage()
        XCTAssertEqual(mock.lastSystemPrompt, "Talking to Alice.")

        // Mutate the dict between sends — the next generation should see the new value.
        vm.systemPromptContext = ["name": "Bob"]
        vm.inputText = "Hi again"
        await vm.sendMessage()

        XCTAssertEqual(
            mock.lastSystemPrompt,
            "Talking to Bob.",
            "Updating systemPromptContext between sends should affect the next generation's effective prompt"
        )
    }
}

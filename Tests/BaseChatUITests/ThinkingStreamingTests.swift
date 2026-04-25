@preconcurrency import XCTest
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Asserts the live-streaming behavior introduced for issue #481: the
/// reasoning block must mutate multiple times during the streaming phase
/// rather than only being written once on `.finalizeThinking`.
@MainActor
final class ThinkingStreamingTests: XCTestCase {

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
        // Force per-token flushes for both batchers so every thinking fragment
        // and visible token causes its own observable mutation, making the
        // intermediate states visible to the test recorder.
        vm.thinkingStreamingUpdateInterval = .zero
        vm.thinkingStreamingBatchCharacterLimit = 1
        vm.streamingUpdateInterval = .zero
        vm.streamingBatchCharacterLimit = 1
        return vm
    }

    // MARK: - 1. Live thinking streams produce multiple part mutations

    func test_thinkingPart_mutatedMultipleTimesBeforeFinalize() async {
        let mock = MockInferenceBackend()
        // Five thinking fragments → at minimum five distinct partial-flush
        // mutations, plus the placeholder insert and the finalize write.
        mock.thinkingTokensToYield = ["Let", " me", " think", " about", " this"]
        mock.tokensToYield = ["done"]
        let vm = makeVM(backend: mock)

        // Wrap onMutateMessage so we record the thinking-part text after each
        // mutation, distinguishing pre-finalize states from the authoritative
        // post-finalize write. The wrapper preserves the original wiring so
        // ChatViewModel state still updates correctly.
        var thinkingTextHistory: [String?] = []
        let originalMutate = vm.generationCoordinator.onMutateMessage
        vm.generationCoordinator.onMutateMessage = { id, body in
            originalMutate(id, body)
            // Reread the message from the view model so we observe the post-
            // mutation state rather than relying on the mutation closure's
            // intent.
            let parts = vm.messages.first(where: { $0.id == id })?.contentParts ?? []
            let thinkingText = parts.compactMap { part -> String? in
                if case .thinking(let s) = part { return s }
                return nil
            }.first
            thinkingTextHistory.append(thinkingText)
        }

        // Capture the exact moment streaming flips off so we can split the
        // history into pre- and post-finalize ranges.
        var preFinalizeCount = 0
        let originalMark = vm.generationCoordinator.onMarkThinkingStreaming
        vm.generationCoordinator.onMarkThinkingStreaming = { id, isStreaming in
            if !isStreaming && preFinalizeCount == 0 {
                preFinalizeCount = thinkingTextHistory.count
            }
            originalMark(id, isStreaming)
        }

        vm.inputText = "hello"
        await vm.sendMessage()

        // Filter to mutations that actually touched a thinking part (a few
        // mutations record nil because they only mutate the visible-text
        // content while no thinking part exists yet — those don't count).
        let preFinalizeThinkingStates = Array(thinkingTextHistory.prefix(preFinalizeCount))
            .compactMap { $0 }

        // Distinct snapshots tell us how many times the *thinking* part
        // changed before finalization. With per-token flushes the count must
        // exceed one (placeholder insert + at least one partial flush).
        let distinctPreFinalize = Set(preFinalizeThinkingStates)
        XCTAssertGreaterThan(
            distinctPreFinalize.count,
            1,
            "Thinking part must be mutated more than once before finalizeThinking. " +
            "Saw \(distinctPreFinalize.count) distinct pre-finalize states: \(distinctPreFinalize). " +
            "Pre-finalize history count: \(preFinalizeCount)."
        )

        // Authoritative final text is the full concatenated reasoning.
        let assistant = vm.messages.first(where: { $0.role == .assistant })
        let finalThinking = assistant?.contentParts.compactMap { part -> String? in
            if case .thinking(let s) = part { return s }
            return nil
        }.first
        XCTAssertEqual(
            finalThinking,
            "Let me think about this",
            "Final thinking text must equal the full concatenated reasoning"
        )
    }

    // MARK: - 2. Streaming flag clears on finalize

    func test_streamingThinkingFlag_clearsOnFinalize() async {
        let mock = MockInferenceBackend()
        mock.thinkingTokensToYield = ["a", "b", "c", "d", "e"]
        mock.tokensToYield = ["ok"]
        let vm = makeVM(backend: mock)

        vm.inputText = "hi"
        await vm.sendMessage()

        XCTAssertTrue(
            vm.messageIDsWithStreamingThinking.isEmpty,
            "messageIDsWithStreamingThinking must be empty after generation completes"
        )
    }
}

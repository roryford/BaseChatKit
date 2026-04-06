import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

@MainActor
final class CompressionP0OrchestratorEdgeCaseTests: XCTestCase {
    private let tokenizer = CharTokenizer()

    func test_shouldCompress_returnsFalse_whenUsableContextBudgetIsZero() {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .automatic

        let result = orchestrator.shouldCompress(
            messages: makeMessages(count: 10, contentLength: 100),
            systemPrompt: nil,
            contextSize: 512,
            tokenizer: tokenizer
        )

        XCTAssertFalse(result, "Zero usable history budget must prevent compression")
    }

    func test_shouldCompress_returnsFalse_whenUsableContextBudgetIsNegative() {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .automatic

        let result = orchestrator.shouldCompress(
            messages: makeMessages(count: 10, contentLength: 100),
            systemPrompt: nil,
            contextSize: 256,
            tokenizer: tokenizer
        )

        XCTAssertFalse(result, "Negative usable history budget must prevent compression")
    }

    func test_shouldCompress_modeChangeAroundDecision_isStablePerInvocation() {
        let orchestrator = CompressionOrchestrator()
        let messages = makeMessages(count: 10, contentLength: 100)

        orchestrator.mode = .automatic
        let decisionWhenAutomatic = orchestrator.shouldCompress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        orchestrator.mode = .off
        let decisionWhenOff = orchestrator.shouldCompress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertTrue(decisionWhenAutomatic, "Decision should reflect .automatic at call time")
        XCTAssertFalse(decisionWhenOff, "Decision should reflect .off at call time")
    }

    func test_compress_modeChangeDuringInFlightCompression_keepsInvocationStrategyStable() async {
        let orchestrator = CompressionOrchestrator()
        let gate = AsyncGate()
        let generationStarted = expectation(description: "Anchored generation started")

        orchestrator.mode = .balanced
        orchestrator.anchored.generateFn = { _ in
            generationStarted.fulfill()
            await gate.wait()
            return "TOPIC: Ava\nKEY POINTS: Station"
        }

        // Ensure history exceeds budget so anchored summarization is invoked.
        let messages = makeMessages(count: 120, contentLength: 80)
        let inFlight = Task {
            await orchestrator.compress(
                messages: messages,
                systemPrompt: nil,
                contextSize: 7_000,
                tokenizer: tokenizer
            )
        }

        await fulfillment(of: [generationStarted], timeout: 1.0)

        orchestrator.mode = .off
        await gate.open()

        let inFlightResult = await inFlight.value
        XCTAssertEqual(inFlightResult.stats.strategy, "anchored",
                       "In-flight compression should keep strategy chosen at invocation time")

        let nextResult = await orchestrator.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 7_000,
            tokenizer: tokenizer
        )
        XCTAssertEqual(nextResult.stats.strategy, "extractive",
                       "Subsequent compression should reflect updated .off mode")
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private func makeMessages(count: Int, contentLength: Int) -> [CompressibleMessage] {
    (0..<count).map { index in
        CompressibleMessage(
            id: UUID(),
            role: index.isMultiple(of: 2) ? "user" : "assistant",
            content: String(repeating: "a", count: contentLength)
        )
    }
}

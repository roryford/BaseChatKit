import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Coverage for ``CompactionTrigger`` and the trigger-aware
/// ``TurnHistoryCompressor/compress(records:trigger:)`` overload.
///
/// The continuation strings are ported verbatim from Goose AI
/// (`crates/goose/src/context_mgmt/mod.rs`) so the model resumes naturally
/// after a compaction instead of acknowledging the summary out loud.
@MainActor
final class CompactionTriggerTests: XCTestCase {

    // MARK: - Fixtures

    private actor Counter {
        private var value = 0
        func next() -> Int {
            defer { value += 1 }
            return value
        }
    }

    private func record(
        step: Int,
        toolName: String = "t",
        args: String = "{}",
        result: String
    ) -> TurnHistoryRecord {
        TurnHistoryRecord(
            step: step,
            intermediateTokens: [],
            toolCalls: [ToolCall(id: "c-\(step)", toolName: toolName, arguments: args)],
            toolResults: [ToolResult(callId: "c-\(step)", content: result, errorKind: nil)]
        )
    }

    /// Builds an over-budget transcript and asserts the produced summary
    /// ends with `expected`.
    private func runTriggerCase(_ trigger: CompactionTrigger, expected: String) {
        let c = BudgetTurnHistoryCompressor(characterBudget: 50, preserveRecentTurns: 1)
        let records = (1...4).map {
            record(step: $0, result: String(repeating: "x", count: 60))
        }
        let out = c.compress(records: records, trigger: trigger)
        XCTAssertFalse(out.foldedRecords.isEmpty, "fixture must trigger a fold")
        XCTAssertTrue(
            out.summary.hasSuffix(expected),
            "summary must end with the trigger-specific continuation prompt; got: \(out.summary)"
        )
    }

    // MARK: - Continuation prompts (Goose-ported)

    func test_automaticTrigger_appendsConversationContinuation() {
        runTriggerCase(.automatic, expected: BudgetTurnHistoryCompressor.conversationContinuationText)
    }

    func test_toolLoopTrigger_appendsToolLoopContinuation() {
        runTriggerCase(.toolLoop, expected: BudgetTurnHistoryCompressor.toolLoopContinuationText)
    }

    func test_manualTrigger_appendsManualCompactContinuation() {
        runTriggerCase(.manual, expected: BudgetTurnHistoryCompressor.manualCompactContinuationText)
    }

    /// The three continuation strings must be distinct — otherwise the
    /// trigger plumbing would be a no-op for any two coincident triggers.
    func test_continuationStrings_areDistinct() {
        let a = BudgetTurnHistoryCompressor.conversationContinuationText
        let b = BudgetTurnHistoryCompressor.toolLoopContinuationText
        let c = BudgetTurnHistoryCompressor.manualCompactContinuationText
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(b, c)
    }

    /// Pin one of the constants to its Goose-source byte sequence. If a
    /// future refactor accidentally rewrites the prose, the regression
    /// surfaces here rather than as a subtle change in model behaviour.
    func test_toolLoopText_matchesGooseSource() {
        XCTAssertEqual(
            BudgetTurnHistoryCompressor.toolLoopContinuationText,
            "Your context was compacted. The previous message contains a summary of the conversation so far.\nDo not mention that you read a summary or that conversation summarization occurred.\nContinue calling tools as necessary to complete the task."
        )
    }

    // MARK: - Default protocol extension

    /// A compressor that only implements the legacy `compress(records:)`
    /// must still honour the trigger-aware call via the default extension.
    /// The trigger argument is intentionally ignored here.
    private struct LegacyOnlyCompressor: TurnHistoryCompressor {
        let marker: String
        func compress(records: [TurnHistoryRecord]) -> CompressedTranscript {
            CompressedTranscript(
                summary: marker,
                foldedRecords: records,
                preservedRecords: []
            )
        }
        // Note: no override of compress(records:trigger:) — the default
        // extension is what we're testing.
    }

    func test_defaultExtension_routesToLegacyMethod_forAllTriggers() {
        let legacy = LegacyOnlyCompressor(marker: "LEGACY")
        let records = [record(step: 1, result: "ok")]
        for trigger in [CompactionTrigger.automatic, .toolLoop, .manual] {
            let out = legacy.compress(records: records, trigger: trigger)
            XCTAssertEqual(
                out.summary,
                "LEGACY",
                "default extension must forward to legacy compress(records:); trigger=\(trigger)"
            )
        }
    }

    // MARK: - Empty-records short-circuit (no continuation appended)

    /// When there is nothing to fold, the compressor returns
    /// `.unchanged(records)` — no summary, and therefore no continuation
    /// prompt. The continuation text only attaches when a fold actually
    /// happens.
    func test_underBudget_doesNotAppendContinuation() {
        let c = BudgetTurnHistoryCompressor(characterBudget: 100_000, preserveRecentTurns: 2)
        let records = (1...3).map { record(step: $0, result: "small") }
        let out = c.compress(records: records, trigger: .toolLoop)
        XCTAssertTrue(out.summary.isEmpty)
        XCTAssertFalse(out.summary.contains(BudgetTurnHistoryCompressor.toolLoopContinuationText))
    }

    // MARK: - Orchestrator passes .toolLoop

    /// Records every `(records, trigger)` pair the orchestrator hands to it.
    /// We capture the trigger argument so we can assert the orchestrator is
    /// passing `.toolLoop` rather than relying on the default.
    private final class RecordingCompressor: TurnHistoryCompressor, @unchecked Sendable {
        // @unchecked: writes are funnelled through a serial DispatchQueue so
        // concurrent compress() invocations from inside the orchestrator's
        // async loop cannot race.
        private let queue = DispatchQueue(label: "RecordingCompressor")
        private var _triggers: [CompactionTrigger] = []

        var observedTriggers: [CompactionTrigger] {
            queue.sync { _triggers }
        }

        func compress(records: [TurnHistoryRecord]) -> CompressedTranscript {
            // Should not be reached when compress(records:trigger:) is
            // overridden, but provide the legacy implementation for safety.
            .unchanged(records)
        }

        func compress(
            records: [TurnHistoryRecord],
            trigger: CompactionTrigger
        ) -> CompressedTranscript {
            queue.sync { _triggers.append(trigger) }
            return .unchanged(records)
        }
    }

    private struct ScriptedExecutor: ToolExecutor {
        let definition: ToolDefinition
        let handler: @Sendable (JSONSchemaValue) async throws -> ToolResult

        init(
            name: String,
            handler: @escaping @Sendable (JSONSchemaValue) async throws -> ToolResult
        ) {
            self.definition = ToolDefinition(name: name, description: "scripted", parameters: .object([:]))
            self.handler = handler
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            try await handler(arguments)
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<ToolLoopEvent, Error>
    ) async throws -> [ToolLoopEvent] {
        var events: [ToolLoopEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    func test_orchestrator_passesToolLoopTrigger() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "any_tool", arguments: #"{"x":1}"#)],
            [ToolCall(id: "c-2", toolName: "any_tool", arguments: #"{"x":2}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], [], ["done"]]

        let counter = Counter()
        let executor = ScriptedExecutor(name: "any_tool") { _ in
            _ = await counter.next()
            return ToolResult(callId: "", content: "ok", errorKind: nil)
        }

        let recording = RecordingCompressor()
        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 4, loopDetectionWindow: 99),
            compressor: recording
        )

        _ = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let observed = recording.observedTriggers
        XCTAssertFalse(observed.isEmpty, "orchestrator must invoke compress at least once per round")
        for trigger in observed {
            switch trigger {
            case .toolLoop: continue
            case .automatic, .manual:
                XCTFail("orchestrator must pass .toolLoop; got \(trigger)")
            }
        }
    }
}

import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Unit and integration coverage for ``TurnHistoryCompressor`` (issue #444).
///
/// Coverage:
/// - Pure compressor: short transcript stays untouched, oversize transcript
///   folds older records, recent N preserved verbatim, summary is structured.
/// - Orchestrator integration: opt-in default behaviour unchanged when the
///   compressor is omitted; round-trip — older fact still recoverable from
///   summary; preserved-records appear verbatim in the next-turn prompt.
@MainActor
final class TurnHistoryCompressorTests: XCTestCase {

    // MARK: - Fixtures

    /// Sendable counter so scripted executor closures (`@Sendable`) can vend
    /// distinct ring-buffer indices across calls without capturing mutable
    /// state — Swift 6 strict-concurrency forbids the latter.
    private actor Counter {
        private var value = 0
        func next() -> Int {
            defer { value += 1 }
            return value
        }
    }

    private func record(
        step: Int,
        toolName: String,
        args: String,
        result: String
    ) -> TurnHistoryRecord {
        TurnHistoryRecord(
            step: step,
            intermediateTokens: [],
            toolCalls: [ToolCall(id: "c-\(step)", toolName: toolName, arguments: args)],
            toolResults: [ToolResult(callId: "c-\(step)", content: result, errorKind: nil)]
        )
    }

    // MARK: - Pure compressor

    func test_emptyRecords_returnsUnchanged() {
        let c = BudgetTurnHistoryCompressor(characterBudget: 100, preserveRecentTurns: 2)
        let out = c.compress(records: [])
        XCTAssertTrue(out.summary.isEmpty)
        XCTAssertEqual(out.foldedRecords.count, 0)
        XCTAssertEqual(out.preservedRecords.count, 0)
    }

    func test_shortTranscript_underBudget_isUnchanged() {
        let c = BudgetTurnHistoryCompressor(characterBudget: 10_000, preserveRecentTurns: 2)
        let records = (1...3).map { record(step: $0, toolName: "t", args: "{}", result: "small") }
        let out = c.compress(records: records)
        XCTAssertTrue(out.summary.isEmpty, "short transcript must not be compressed; got: \(out.summary)")
        XCTAssertEqual(out.foldedRecords.count, 0)
        XCTAssertEqual(out.preservedRecords.count, 3)
    }

    func test_overBudget_foldsOlderAndPreservesRecentN() {
        // Budget ~ 80 chars; build 6 records of ~50 chars each → way over
        // budget. preserveRecentTurns=2 must keep exactly the last 2.
        let c = BudgetTurnHistoryCompressor(characterBudget: 80, preserveRecentTurns: 2)
        let records = (1...6).map {
            record(step: $0, toolName: "weather", args: #"{"city":"Rome"}"#, result: String(repeating: "x", count: 50))
        }
        let out = c.compress(records: records)

        XCTAssertEqual(out.preservedRecords.count, 2, "must preserve preserveRecentTurns=2 verbatim")
        XCTAssertEqual(out.preservedRecords.first?.step, 5)
        XCTAssertEqual(out.preservedRecords.last?.step, 6)
        XCTAssertEqual(out.foldedRecords.count, 4)
        XCTAssertFalse(out.summary.isEmpty)
        XCTAssertTrue(out.summary.contains("4 rounds"), "summary must report rounds folded; got: \(out.summary)")
    }

    func test_summaryIncludesNotableResults_andStepReferences() {
        // Budget 30 + records of ~50 chars each. Folding stops as soon as
        // the *remaining* suffix fits the budget — this is the right
        // contract for the orchestrator (do as little compression as
        // necessary). With 4 records of ~50 chars each, folding the first
        // 3 brings remaining to ~50 — still over 30 — so all foldable
        // records are folded down to the preserve floor (1).
        let c = BudgetTurnHistoryCompressor(characterBudget: 30, preserveRecentTurns: 1, maxResultExcerpts: 3)
        let big = String(repeating: "x", count: 30)
        let records = [
            record(step: 1, toolName: "weather", args: #"{"city":"Rome"}"#, result: "18C-\(big)"),
            record(step: 2, toolName: "search", args: #"{"q":"swift"}"#, result: "21 hits-\(big)"),
            record(step: 3, toolName: "math", args: "{}", result: "42-\(big)"),
            record(step: 4, toolName: "final", args: "{}", result: "ok"),
        ]
        let out = c.compress(records: records)

        // Step 4 must be preserved verbatim (preserveRecentTurns=1).
        XCTAssertEqual(out.preservedRecords.map(\.step), [4])
        // Earlier steps must be cited by step number in the summary so a
        // later round can still reference "step 2: search → 21 hits".
        XCTAssertTrue(out.summary.contains("step 1"), "summary must cite step 1; got: \(out.summary)")
        XCTAssertTrue(out.summary.contains("18C"), "summary must include weather result; got: \(out.summary)")
        XCTAssertTrue(out.summary.contains("21 hits"), "summary must include search result; got: \(out.summary)")
    }

    func test_idempotent_onAlreadyCompressedSuffix() {
        let c = BudgetTurnHistoryCompressor(characterBudget: 100_000, preserveRecentTurns: 2)
        let records = (1...3).map { record(step: $0, toolName: "t", args: "{}", result: "ok") }
        let first = c.compress(records: records)
        let second = c.compress(records: first.preservedRecords)
        XCTAssertEqual(first.preservedRecords, second.preservedRecords)
        XCTAssertTrue(second.summary.isEmpty)
    }

    func test_noOpCompressor_alwaysReturnsUnchanged() {
        let c = NoOpTurnHistoryCompressor()
        let records = (1...3).map { record(step: $0, toolName: "t", args: "{}", result: "ok") }
        let out = c.compress(records: records)
        XCTAssertEqual(out.preservedRecords, records)
        XCTAssertTrue(out.foldedRecords.isEmpty)
        XCTAssertTrue(out.summary.isEmpty)
    }

    // MARK: - Orchestrator integration

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

    private func makeBackend() -> MockInferenceBackend {
        let b = MockInferenceBackend()
        b.isModelLoaded = true
        return b
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

    func test_defaultOff_existingPromptShapeUnchanged() async throws {
        // No compressor argument → existing wire format must be byte-for-byte
        // identical to the pre-compression behaviour. This is the opt-in
        // guard: shipping #444 must not perturb apps that don't enable it.
        let backend = makeBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "any_tool", arguments: #"{"x":1}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let executor = ScriptedExecutor(name: "any_tool") { _ in
            ToolResult(callId: "", content: "ok", errorKind: nil)
        }

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        _ = try await collect(orchestrator.run(
            initialPrompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let prompt = try XCTUnwrap(backend.lastPrompt)
        XCTAssertTrue(prompt.contains("Tool 'any_tool' result: ok"))
        XCTAssertFalse(prompt.contains("Earlier turns summarised"), "default-off compressor must not inject any summary; got: \(prompt)")
    }

    func test_compressionEnabled_foldsOldResultsAfterBudget() async throws {
        // Five tool turns, each emitting a long result. Tiny budget +
        // preserveRecentTurns=1 forces the compressor to fold turns 1–3 by
        // the time turn 5 generates. The final-turn prompt must contain the
        // summary and the verbatim turn-4 appendix, but not the earlier
        // verbatim appendices.
        let backend = makeBackend()
        let bigResult = String(repeating: "X", count: 200)
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "search", arguments: #"{"q":"first"}"#)],
            [ToolCall(id: "c-2", toolName: "search", arguments: #"{"q":"second"}"#)],
            [ToolCall(id: "c-3", toolName: "search", arguments: #"{"q":"third"}"#)],
            [ToolCall(id: "c-4", toolName: "search", arguments: #"{"q":"fourth"}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], [], [], [], ["done"]]

        // Distinct results so we can prove which were folded vs. preserved.
        let resultsRing = ["RES_FIRST=\(bigResult)", "RES_SECOND=\(bigResult)", "RES_THIRD=\(bigResult)", "RES_FOURTH=\(bigResult)"]
        let counter = Counter()
        let executor = ScriptedExecutor(name: "search") { _ in
            let idx = await counter.next()
            return ToolResult(callId: "", content: resultsRing[idx], errorKind: nil)
        }

        let compressor = BudgetTurnHistoryCompressor(
            characterBudget: 100,
            preserveRecentTurns: 1,
            maxResultExcerpts: 5,
            maxResultExcerptLength: 24
        )

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 6, loopDetectionWindow: 99),
            compressor: compressor
        )

        let events = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        // Sanity: orchestrator must have run all 5 generate rounds. If it
        // bailed early, lastPrompt would record the wrong turn and the
        // assertions below would be testing the wrong thing.
        XCTAssertEqual(backend.generateCallCount, 5, "events: \(events)")

        let lastPrompt = try XCTUnwrap(backend.lastPrompt)

        // Most recent (4th) turn must appear verbatim — round-trip property.
        XCTAssertTrue(
            lastPrompt.contains("RES_FOURTH=\(bigResult)"),
            "preserveRecentTurns=1 must keep the latest result verbatim"
        )
        // The summary block must be present and reference the older steps
        // (round-trip — the model can still answer about earlier results).
        XCTAssertTrue(
            lastPrompt.contains("Earlier turns summarised"),
            "compressor must emit a summary when over budget"
        )
        // Summary must cite at least one of the older steps so the model
        // can refer back to it. step 1 is the oldest folded record.
        XCTAssertTrue(
            lastPrompt.contains("step 1"),
            "summary must cite step 1 so older facts stay referenceable; got: \(lastPrompt)"
        )
        // Earlier verbatim payloads must NOT survive. We assert on the long
        // RES_FIRST signature (truncation in the summary keeps only the
        // first ~24 chars, so the full bigResult string cannot appear).
        let firstVerbatim = "RES_FIRST=\(bigResult)"
        XCTAssertFalse(
            lastPrompt.contains(firstVerbatim),
            "verbatim earliest result must have been folded out"
        )
    }

    func test_compressorOmitted_recordsAreRetainedVerbatim() async throws {
        // A run with the no-op compressor (default) must accumulate every
        // tool result in the final prompt, byte-for-byte. This is the
        // negative control for the budget test above.
        let backend = makeBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "search", arguments: #"{"q":"a"}"#)],
            [ToolCall(id: "c-2", toolName: "search", arguments: #"{"q":"b"}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], [], ["fin"]]

        let counter = Counter()
        let executor = ScriptedExecutor(name: "search") { _ in
            let idx = await counter.next()
            let label = idx == 0 ? "RES_A" : "RES_B"
            return ToolResult(callId: "", content: label, errorKind: nil)
        }

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 5, loopDetectionWindow: 99)
        )

        _ = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let prompt = try XCTUnwrap(backend.lastPrompt)
        XCTAssertTrue(prompt.contains("RES_A"))
        XCTAssertTrue(prompt.contains("RES_B"))
    }
}

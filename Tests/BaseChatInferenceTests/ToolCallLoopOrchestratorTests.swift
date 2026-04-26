import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Unit tests for ``ToolCallLoopOrchestrator`` (issue #443).
///
/// Coverage:
/// - happy path: single-tool round-trip then a final text turn
/// - step-limit cap: scripts more tool turns than the policy allows
/// - loop detection: identical `(name, args)` repeated `loopDetectionWindow` times
/// - cancellation: drop the consumer mid-stream and assert the backend was stopped
/// - tool-error propagation: executor throws → result carries `.permanent`
@MainActor
final class ToolCallLoopOrchestratorTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal executor whose handler is supplied at construction time.
    private struct ScriptedExecutor: ToolExecutor {
        let definition: ToolDefinition
        let handler: @Sendable (JSONSchemaValue) async throws -> ToolResult

        init(
            name: String = "any_tool",
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
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        return backend
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

    // MARK: - Happy path

    func test_singleToolThenFinalText_emitsExpectedSequence() async throws {
        let backend = makeBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-1", toolName: "any_tool", arguments: #"{"x":1}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [
            [],
            ["Hello", " world"],
        ]

        let executor = ScriptedExecutor { _ in
            ToolResult(callId: "", content: "ok", errorKind: nil)
        }

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let events = try await collect(orchestrator.run(
            initialPrompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        // Expected sequence: .toolCall → .toolResult → .token("Hello")
        // → .token(" world") → .finished
        XCTAssertEqual(events.count, 5, "events: \(events)")
        guard case .toolCall(let call) = events[0] else {
            return XCTFail("first event must be .toolCall, got \(events[0])")
        }
        XCTAssertEqual(call.id, "c-1")
        XCTAssertEqual(call.toolName, "any_tool")

        guard case .toolResult(let result) = events[1] else {
            return XCTFail("second event must be .toolResult, got \(events[1])")
        }
        XCTAssertEqual(result.callId, "c-1")
        XCTAssertEqual(result.content, "ok")
        XCTAssertNil(result.errorKind)

        XCTAssertEqual(events[2], .token("Hello"))
        XCTAssertEqual(events[3], .token(" world"))
        XCTAssertEqual(events[4], .finished)

        // The orchestrator must have re-prompted with the result content
        // appended verbatim — sabotage check pivot.
        XCTAssertEqual(backend.generateCallCount, 2)
        XCTAssertNotNil(backend.lastPrompt)
        XCTAssertTrue(
            backend.lastPrompt?.contains("Tool 'any_tool' result: ok") == true,
            "second-turn prompt must contain the appended tool result; got: \(backend.lastPrompt ?? "nil")"
        )
    }

    // MARK: - Step limit

    func test_stepLimitReached_whenScriptExceedsBudget() async throws {
        let backend = makeBackend()
        // Five distinct tool turns, but maxSteps = 3 → loop must terminate
        // with .stepLimitReached(steps: 3) before the fourth turn runs.
        backend.scriptedToolCallsPerTurn = (0..<5).map { idx in
            [ToolCall(id: "c-\(idx)", toolName: "spam", arguments: #"{"i":\#(idx)}"#)]
        }
        backend.tokensToYieldPerTurn = Array(repeating: [], count: 5)

        let executor = ScriptedExecutor(name: "spam") { _ in
            ToolResult(callId: "", content: "ok", errorKind: nil)
        }

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 3, loopDetectionWindow: 99)
        )

        let events = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        guard case .stepLimitReached(let steps) = events.last else {
            return XCTFail("last event must be .stepLimitReached, got \(events)")
        }
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(backend.generateCallCount, 3)
    }

    // MARK: - Loop detection

    func test_loopDetected_firesOnIdenticalCallsRepeated() async throws {
        let backend = makeBackend()
        let identical = ToolCall(id: "c", toolName: "spin", arguments: #"{"k":1}"#)
        backend.scriptedToolCallsPerTurn = [
            [identical], [identical], [identical], [identical], [identical],
        ]
        backend.tokensToYieldPerTurn = Array(repeating: [], count: 5)

        let executor = ScriptedExecutor(name: "spin") { _ in
            ToolResult(callId: "", content: "ok", errorKind: nil)
        }

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 10, loopDetectionWindow: 3)
        )

        let events = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        guard case .loopDetected(let toolName) = events.last else {
            return XCTFail("last event must be .loopDetected, got \(events)")
        }
        XCTAssertEqual(toolName, "spin")
        // Loop must have fired on the third identical call — the third
        // generate() round produced the third identical signature, so the
        // backend was invoked exactly three times.
        XCTAssertEqual(backend.generateCallCount, 3)
    }

    // MARK: - Cancellation

    func test_cancellation_propagatesStopGeneration_andHaltsEvents() async throws {
        let backend = makeBackend()
        // Long token stream so the cancellation has time to land.
        backend.tokensToYield = (0..<1_000).map { "tok\($0) " }

        let executor = ScriptedExecutor { _ in
            ToolResult(callId: "", content: "ok", errorKind: nil)
        }

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let stream = orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let consumer = Task {
            var seen = 0
            for try await _ in stream {
                seen += 1
                if seen >= 1 { break }
            }
            return seen
        }

        // Wait for the consumer to break out, which fires the stream's
        // onTermination handler (driver.cancel + backend.stopGeneration).
        _ = try await consumer.value

        // onTermination is asynchronous; spin briefly until the stop count
        // moves. Tight bound — under 100 ms in practice.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while backend.stopCallCount == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }

        XCTAssertGreaterThanOrEqual(
            backend.stopCallCount,
            1,
            "backend.stopGeneration() must be invoked when the consumer drops the stream"
        )
    }

    // MARK: - Tool error propagation

    func test_executorThrows_resultClassifiedAsPermanent() async throws {
        struct Boom: Error {}

        let backend = makeBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-9", toolName: "boom", arguments: "{}")],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let executor = ScriptedExecutor(name: "boom") { _ in
            throw Boom()
        }

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            executor: executor,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let events = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let result = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }.first

        let unwrapped = try XCTUnwrap(result, "orchestrator must surface a .toolResult after the executor throws")
        XCTAssertEqual(unwrapped.errorKind, .permanent)
        XCTAssertEqual(unwrapped.callId, "c-9")
    }

    // MARK: - Parallel dispatch fixtures

    /// Test executor that gates `execute(arguments:)` on a per-call
    /// continuation. Lets tests assert all N calls have *entered* execute()
    /// before any is allowed to *return*. Stateless from the orchestrator's
    /// point of view — `supportsConcurrentDispatch` is configurable.
    @MainActor
    private final class BlockingToolExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        let supportsConcurrentDispatch: Bool

        /// Continuations keyed by the unique tag the test injects via
        /// `ToolCall.arguments` (we use a `{"tag":"..."}` JSON shape). The
        /// test resolves a continuation to release that one in-flight call.
        private var gates: [String: CheckedContinuation<String, Never>] = [:]

        /// Tags that have entered `execute()` but not yet been released.
        /// Surface for the test to spin on.
        private(set) var enteredTags: Set<String> = []

        /// Tags in the order their executions finished. Used by the
        /// reverse-completion-order test to assert determinism of the
        /// next-prompt assembly.
        private(set) var completedTagsInOrder: [String] = []

        init(name: String, supportsConcurrentDispatch: Bool) {
            self.definition = ToolDefinition(name: name, description: "blocking", parameters: .object([:]))
            self.supportsConcurrentDispatch = supportsConcurrentDispatch
        }

        func release(tag: String, with content: String) {
            guard let cont = gates.removeValue(forKey: tag) else { return }
            cont.resume(returning: content)
        }

        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            // Pull the tag from the arguments — `{"tag":"..."}`.
            var tag = ""
            if case .object(let dict) = arguments,
               case .string(let s) = dict["tag"] {
                tag = s
            }
            let capturedTag = tag
            let content: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                Task { @MainActor [capturedTag] in
                    self.enteredTags.insert(capturedTag)
                    self.gates[capturedTag] = cont
                }
            }
            await MainActor.run { [capturedTag] in
                self.completedTagsInOrder.append(capturedTag)
            }
            return ToolResult(callId: "", content: content, errorKind: nil)
        }
    }

    /// Sequential-only executor that records the order in which `execute()`
    /// is entered. Used to assert sequential semantics on the fallback path.
    @MainActor
    private final class RecordingSequentialExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        let supportsConcurrentDispatch: Bool
        private(set) var enteredTagsInOrder: [String] = []

        init(name: String, supportsConcurrentDispatch: Bool = false) {
            self.definition = ToolDefinition(name: name, description: "sequential", parameters: .object([:]))
            self.supportsConcurrentDispatch = supportsConcurrentDispatch
        }

        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            var tag = ""
            if case .object(let dict) = arguments, case .string(let s) = dict["tag"] {
                tag = s
            }
            let capturedTag = tag
            await MainActor.run { [capturedTag] in
                self.enteredTagsInOrder.append(capturedTag)
            }
            return ToolResult(callId: "", content: "ok-\(capturedTag)", errorKind: nil)
        }
    }

    // MARK: - Parallel dispatch tests (#621)

    func test_parallelDispatch_whenAllExecutorsSupportConcurrent_runsConcurrently() async throws {
        let backend = makeBackend()
        let calls = (0..<3).map { i in
            ToolCall(id: "p-\(i)", toolName: "blocker", arguments: #"{"tag":"t\#(i)"}"#)
        }
        backend.scriptedToolCallsPerTurn = [calls, []]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let executor = BlockingToolExecutor(name: "blocker", supportsConcurrentDispatch: true)
        let registry = ToolRegistry()
        registry.register(executor)

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            registry: registry,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let stream = orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let consumer = Task {
            try await self.collect(stream)
        }

        // Wait until all three calls have entered execute() concurrently —
        // the assertion is that all three enter before any returns. Spin
        // bounded.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await executor.enteredTags.count < 3 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        let entered = await executor.enteredTags
        XCTAssertEqual(entered, Set(["t0", "t1", "t2"]), "all three calls must be in flight together; got: \(entered)")
        let completedSoFar = await executor.completedTagsInOrder
        XCTAssertTrue(completedSoFar.isEmpty, "no executor should have completed yet")

        // Release in arbitrary order. Sequence must still finish cleanly.
        await executor.release(tag: "t1", with: "r1")
        await executor.release(tag: "t0", with: "r0")
        await executor.release(tag: "t2", with: "r2")

        let events = try await consumer.value

        // Three .toolResult events fire. The exact emission order matches
        // batch-emission order (t0,t1,t2) — see preservesBatchOrder test.
        let resultCount = events.filter { if case .toolResult = $0 { return true } else { return false } }.count
        XCTAssertEqual(resultCount, 3)
    }

    func test_parallelDispatch_preservesBatchOrderInResults() async throws {
        let backend = makeBackend()
        let calls = (0..<3).map { i in
            ToolCall(id: "ord-\(i)", toolName: "blocker", arguments: #"{"tag":"t\#(i)"}"#)
        }
        backend.scriptedToolCallsPerTurn = [calls, []]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let executor = BlockingToolExecutor(name: "blocker", supportsConcurrentDispatch: true)
        let registry = ToolRegistry()
        registry.register(executor)

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            registry: registry,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let stream = orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let consumer = Task { try await self.collect(stream) }

        // Wait for all three to enter execute() concurrently.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await executor.enteredTags.count < 3 && ContinuousClock.now < deadline {
            await Task.yield()
        }

        // Release in REVERSE batch order — completion order (t2, t1, t0)
        // diverges from emission order (t0, t1, t2). The orchestrator must
        // still yield .toolResult / build the prompt appendix in batch
        // order.
        await executor.release(tag: "t2", with: "r2")
        await executor.release(tag: "t1", with: "r1")
        await executor.release(tag: "t0", with: "r0")

        let events = try await consumer.value

        // Sabotage check pivot: change the dispatchParallel sort to
        // descending and this assertion flips.
        let resultCallIds = events.compactMap { e -> String? in
            if case .toolResult(let r) = e { return r.callId } else { return nil }
        }
        XCTAssertEqual(resultCallIds, ["ord-0", "ord-1", "ord-2"], "results must surface in batch-emission order, not completion order")

        // The next-turn prompt must concatenate results in batch order too.
        let lastPrompt = backend.lastPrompt ?? ""
        let r0Range = lastPrompt.range(of: "result: r0")
        let r1Range = lastPrompt.range(of: "result: r1")
        let r2Range = lastPrompt.range(of: "result: r2")
        XCTAssertNotNil(r0Range)
        XCTAssertNotNil(r1Range)
        XCTAssertNotNil(r2Range)
        if let r0 = r0Range?.lowerBound, let r1 = r1Range?.lowerBound, let r2 = r2Range?.lowerBound {
            XCTAssertLessThan(r0, r1, "prompt must list r0 before r1")
            XCTAssertLessThan(r1, r2, "prompt must list r1 before r2")
        }
    }

    func test_parallelDispatch_fallsBackToSequential_whenOneExecutorOptsOut() async throws {
        let backend = makeBackend()
        let calls = [
            ToolCall(id: "a", toolName: "alpha", arguments: #"{"tag":"a"}"#),
            ToolCall(id: "b", toolName: "beta",  arguments: #"{"tag":"b"}"#),
            ToolCall(id: "c", toolName: "gamma", arguments: #"{"tag":"c"}"#),
        ]
        backend.scriptedToolCallsPerTurn = [calls, []]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let alpha = RecordingSequentialExecutor(name: "alpha", supportsConcurrentDispatch: true)
        // beta opts out — single dissenter forces sequential dispatch for
        // the whole batch.
        let beta  = RecordingSequentialExecutor(name: "beta",  supportsConcurrentDispatch: false)
        let gamma = RecordingSequentialExecutor(name: "gamma", supportsConcurrentDispatch: true)

        let registry = ToolRegistry()
        registry.register(alpha)
        registry.register(beta)
        registry.register(gamma)

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            registry: registry,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let events = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        // Sequential dispatch enters executors strictly in batch order.
        XCTAssertEqual(alpha.enteredTagsInOrder, ["a"])
        XCTAssertEqual(beta.enteredTagsInOrder, ["b"])
        XCTAssertEqual(gamma.enteredTagsInOrder, ["c"])

        let resultIds = events.compactMap { e -> String? in
            if case .toolResult(let r) = e { return r.callId } else { return nil }
        }
        XCTAssertEqual(resultIds, ["a", "b", "c"])
    }

    func test_parallelDispatch_cancellation_dropsLateResults() async throws {
        let backend = makeBackend()
        let calls = (0..<3).map { i in
            ToolCall(id: "x-\(i)", toolName: "blocker", arguments: #"{"tag":"t\#(i)"}"#)
        }
        backend.scriptedToolCallsPerTurn = [calls, []]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let executor = BlockingToolExecutor(name: "blocker", supportsConcurrentDispatch: true)
        let registry = ToolRegistry()
        registry.register(executor)

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            registry: registry,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let stream = orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // Drain the toolCall events but break before any results land.
        let consumer = Task { () -> [ToolLoopEvent] in
            var seen: [ToolLoopEvent] = []
            do {
                for try await event in stream {
                    seen.append(event)
                    if case .toolCall = event {
                        if seen.filter({ if case .toolCall = $0 { return true } else { return false } }).count >= 3 {
                            // Got all three .toolCall events. Drop the
                            // stream — the parallel dispatch is now in
                            // flight. onTermination cancels the driver.
                            break
                        }
                    }
                }
            } catch {
                // Expected during cancellation.
            }
            return seen
        }

        // Wait for all three executors to enter execute() so cancellation
        // hits the in-flight task group.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await executor.enteredTags.count < 3 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        let enteredCount = await executor.enteredTags.count
        XCTAssertEqual(enteredCount, 3)

        // Consumer drops the stream. Cancellation propagates into the task
        // group. Now release one of the executors — this would normally
        // produce a .toolResult, but the consumer is gone and the
        // orchestrator's parallel path checks Task.isCancelled before
        // yielding anything.
        let observed = try await consumer.value
        await executor.release(tag: "t0", with: "late")
        await executor.release(tag: "t1", with: "late")
        await executor.release(tag: "t2", with: "late")

        // No .toolResult events were observed by the consumer.
        let toolResults = observed.filter { if case .toolResult = $0 { return true } else { return false } }
        XCTAssertEqual(toolResults.count, 0, "no .toolResult should have leaked after cancellation; saw: \(observed)")
    }

    // MARK: - Streaming delta forwarding

    func test_streamingDeltas_forwardedThroughOrchestrator() async throws {
        let backend = makeBackend()
        // Backend emits two streamed calls in a single turn:
        //   start(c1) → delta(c1,'{"a"') → delta(c1,':1}') → call(c1)
        //   start(c2) → delta(c2,'{"b":2}') → call(c2)
        // then a quiet final turn with one visible token.
        let call1 = ToolCall(id: "c1", toolName: "first",  arguments: #"{"a":1}"#)
        let call2 = ToolCall(id: "c2", toolName: "second", arguments: #"{"b":2}"#)
        backend.scriptedToolCallDeltasPerTurn = [
            [
                .start(callId: "c1", name: "first"),
                .delta(callId: "c1", textDelta: #"{"a"#),
                .delta(callId: "c1", textDelta: #"":1}"#),
                .call(call1),
                .start(callId: "c2", name: "second"),
                .delta(callId: "c2", textDelta: #"{"b":2}"#),
                .call(call2),
            ],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["bye"]]

        let executor = ScriptedExecutor(name: "first") { _ in
            ToolResult(callId: "", content: "ok-1", errorKind: nil)
        }
        let executor2 = ScriptedExecutor(name: "second") { _ in
            ToolResult(callId: "", content: "ok-2", errorKind: nil)
        }
        let registry = ToolRegistry()
        registry.register(executor)
        registry.register(executor2)

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            registry: registry,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let events = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        // Pull the streaming-delta events in the order they appeared.
        let streamShape: [ToolLoopEvent] = events.compactMap { e in
            switch e {
            case .toolCallStart, .toolCallArgumentsDelta, .toolCall:
                return e
            default:
                return nil
            }
        }

        XCTAssertEqual(
            streamShape.count,
            7,
            "must forward 2 .toolCallStart + 3 .toolCallArgumentsDelta + 2 .toolCall events verbatim"
        )
        XCTAssertEqual(streamShape[0], .toolCallStart(callId: "c1", name: "first"))
        XCTAssertEqual(streamShape[1], .toolCallArgumentsDelta(callId: "c1", textDelta: #"{"a"#))
        XCTAssertEqual(streamShape[2], .toolCallArgumentsDelta(callId: "c1", textDelta: #"":1}"#))
        if case .toolCall(let c) = streamShape[3] {
            XCTAssertEqual(c.id, "c1")
        } else {
            XCTFail("event 3 must be .toolCall(c1)")
        }
        XCTAssertEqual(streamShape[4], .toolCallStart(callId: "c2", name: "second"))
        XCTAssertEqual(streamShape[5], .toolCallArgumentsDelta(callId: "c2", textDelta: #"{"b":2}"#))
        if case .toolCall(let c) = streamShape[6] {
            XCTAssertEqual(c.id, "c2")
        } else {
            XCTFail("event 6 must be .toolCall(c2)")
        }
    }

    // MARK: - Registry init

    func test_registryInit_routesByToolName() async throws {
        let backend = makeBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-r", toolName: "registered", arguments: "{}")],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["bye"]]

        let registry = ToolRegistry()
        registry.register(ScriptedExecutor(name: "registered") { _ in
            ToolResult(callId: "", content: "from-registry", errorKind: nil)
        })

        let orchestrator = ToolCallLoopOrchestrator(
            backend: backend,
            registry: registry,
            policy: ToolCallLoopPolicy(maxSteps: 4)
        )

        let events = try await collect(orchestrator.run(
            initialPrompt: "go",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let result = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }.first

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.content, "from-registry")
        XCTAssertEqual(unwrapped.callId, "c-r")
    }
}

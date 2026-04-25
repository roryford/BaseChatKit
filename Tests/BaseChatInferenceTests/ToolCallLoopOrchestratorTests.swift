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

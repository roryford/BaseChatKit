import XCTest
@testable import BaseChatInference

/// Integration tests for ``ToolRegistry``'s reentrancy contract:
/// dispatches resolve their executor exactly once at entry, and registry
/// mutations during a suspended dispatch do not retarget the in-flight call.
@MainActor
final class ToolRegistryReentrancyTests: XCTestCase {

    // MARK: - Fixtures

    /// Executor that sleeps for a configurable duration before returning a
    /// caller-supplied marker. Sleep is short enough to keep CI snappy; the
    /// suspension is what the tests rely on, not the wall-clock time.
    private struct SlowMarkerExecutor: ToolExecutor {
        let definition: ToolDefinition
        let marker: String
        let sleep: Duration

        init(name: String, marker: String, sleep: Duration = .milliseconds(150)) {
            self.definition = ToolDefinition(name: name, description: "marker", parameters: .object([:]))
            self.marker = marker
            self.sleep = sleep
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            try await Task.sleep(for: sleep)
            return ToolResult(callId: "", content: marker, errorKind: nil)
        }
    }

    /// Fast executor used as the post-mutation replacement.
    private struct FastMarkerExecutor: ToolExecutor {
        let definition: ToolDefinition
        let marker: String

        init(name: String, marker: String) {
            self.definition = ToolDefinition(name: name, description: "marker", parameters: .object([:]))
            self.marker = marker
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            ToolResult(callId: "", content: marker, errorKind: nil)
        }
    }

    private func makeCall(name: String, id: String = "call-1") -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: "{}")
    }

    // MARK: - Mid-dispatch register replaces the executor for *future* dispatches

    func test_midDispatchRegister_doesNotRetargetInflightDispatch() async throws {
        let registry = ToolRegistry()
        let slowA = SlowMarkerExecutor(name: "weather", marker: "A-result")
        registry.register(slowA)

        // Kick off the slow dispatch in a child task. It will suspend inside
        // execute(arguments:) for ~150 ms, giving us a window to mutate.
        let call = makeCall(name: "weather", id: "first")
        let firstTask = Task { @MainActor in
            await registry.dispatch(call)
        }

        // Yield, then mutate the registry mid-flight. A short sleep guarantees
        // the dispatch has already entered the suspension before we swap.
        try await Task.sleep(for: .milliseconds(20))
        registry.register(FastMarkerExecutor(name: "weather", marker: "B-result"))

        let firstAwaited = await firstTask.value
        XCTAssertEqual(firstAwaited.content, "A-result")
        XCTAssertNil(firstAwaited.errorKind)

        // The second dispatch sees the post-mutation table.
        let second = await registry.dispatch(makeCall(name: "weather", id: "second"))
        XCTAssertEqual(second.content, "B-result")
        XCTAssertNil(second.errorKind)
    }

    // MARK: - Mid-dispatch unregister still completes the in-flight call

    func test_midDispatchUnregister_inflightDispatchCompletes_secondDispatchIsUnknown() async throws {
        let registry = ToolRegistry()
        registry.register(SlowMarkerExecutor(name: "weather", marker: "A-result"))

        let call = makeCall(name: "weather", id: "first")
        let firstTask = Task { @MainActor in
            await registry.dispatch(call)
        }

        try await Task.sleep(for: .milliseconds(20))
        // The unregister-while-in-flight path emits a Log.inference.warning;
        // we verify behaviour, not the log line.
        registry.unregister(name: "weather")

        let firstAwaited = await firstTask.value
        XCTAssertEqual(firstAwaited.content, "A-result")
        XCTAssertNil(firstAwaited.errorKind)

        let second = await registry.dispatch(makeCall(name: "weather", id: "second"))
        XCTAssertEqual(second.errorKind, .unknownTool)
    }

    // MARK: - definitions snapshot reflects the post-mutation state mid-dispatch

    func test_definitionsSnapshot_takenMidDispatch_reflectsPostMutationState() async throws {
        let registry = ToolRegistry()
        registry.register(SlowMarkerExecutor(name: "weather", marker: "A-result"))

        let call = makeCall(name: "weather", id: "first")
        let firstTask = Task { @MainActor in
            await registry.dispatch(call)
        }

        try await Task.sleep(for: .milliseconds(20))

        // Snapshot reflects the *current* table, even though a dispatch is
        // suspended against an entry that's about to be replaced.
        let beforeReplacement = registry.definitions.map(\.name)
        XCTAssertEqual(beforeReplacement, ["weather"])

        registry.register(FastMarkerExecutor(name: "calculator", marker: "calc"))
        registry.unregister(name: "weather")

        let afterMutation = registry.definitions.map(\.name)
        XCTAssertEqual(afterMutation, ["calculator"])

        // The in-flight dispatch still completes against the original
        // executor — the mutation is visible to readers but doesn't
        // retarget the call.
        let firstAwaited = await firstTask.value
        XCTAssertEqual(firstAwaited.content, "A-result")
    }
}

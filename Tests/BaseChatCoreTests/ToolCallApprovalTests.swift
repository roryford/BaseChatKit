import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

/// Exercises the approval gate in isolation from any backend. The gate
/// enforces three behaviours the rest of BaseChatKit depends on:
///
/// - `.alwaysAsk` pauses every call until the UI resolves it.
/// - `.trustedTools` auto-approves matches and pauses everything else.
/// - `.autoApprove` passes every call through untouched.
///
/// Rejection and argument-edit paths also live here because they are
/// decisions the gate itself makes before any `ToolProvider.execute` runs.
@MainActor
final class ToolCallApprovalTests: XCTestCase {

    private func makeCall(id: String = "call_1", name: String = "send_email", arguments: String = #"{"to":"a@b.com"}"#) -> ToolCall {
        ToolCall(id: id, name: name, arguments: arguments)
    }

    // MARK: - Mode behaviour

    func test_autoApprove_returnsApprovedWithOriginalArguments() async {
        let coordinator = ToolCallApprovalCoordinator(mode: .autoApprove)
        let call = makeCall()

        let decision = await coordinator.requestDecision(for: call)

        guard case .approved(let args) = decision else {
            XCTFail("Expected .approved, got \(decision)")
            return
        }
        XCTAssertEqual(args, call.arguments)
        XCTAssertTrue(coordinator.pendingApprovals.isEmpty)
    }

    func test_alwaysAsk_suspendsUntilResolved() async {
        let coordinator = ToolCallApprovalCoordinator(mode: .alwaysAsk)
        let call = makeCall()

        let task = Task { () -> ToolCallApprovalDecision in
            await coordinator.requestDecision(for: call)
        }

        // Poll for the pending approval showing up. No artificial sleeps —
        // we just yield to the scheduler until the continuation is filed.
        for _ in 0..<100 {
            if !coordinator.pendingApprovals.isEmpty { break }
            await Task.yield()
        }

        XCTAssertEqual(coordinator.pendingApprovals.count, 1)
        XCTAssertEqual(coordinator.pendingApprovals.first?.id, call.id)

        coordinator.resolve(id: call.id, with: .approved(arguments: call.arguments))

        let decision = await task.value
        guard case .approved = decision else {
            XCTFail("Expected .approved, got \(decision)")
            return
        }
        XCTAssertTrue(coordinator.pendingApprovals.isEmpty)
    }

    func test_trustedTools_autoApprovesListedName() async {
        let coordinator = ToolCallApprovalCoordinator(mode: .trustedTools(["get_weather"]))
        let trusted = makeCall(name: "get_weather", arguments: "{}")

        let decision = await coordinator.requestDecision(for: trusted)

        guard case .approved = decision else {
            XCTFail("Trusted tool should auto-approve, got \(decision)")
            return
        }
        XCTAssertTrue(coordinator.pendingApprovals.isEmpty)
    }

    func test_trustedTools_stillPausesOtherTools() async {
        let coordinator = ToolCallApprovalCoordinator(mode: .trustedTools(["get_weather"]))
        let risky = makeCall(name: "delete_file")

        let task = Task { () -> ToolCallApprovalDecision in
            await coordinator.requestDecision(for: risky)
        }
        for _ in 0..<100 {
            if !coordinator.pendingApprovals.isEmpty { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.pendingApprovals.count, 1)

        coordinator.resolve(id: risky.id, with: .rejected(reason: "nope"))
        let decision = await task.value
        guard case .rejected(let reason) = decision else {
            XCTFail("Expected .rejected, got \(decision)")
            return
        }
        XCTAssertEqual(reason, "nope")
    }

    // MARK: - Rejection synthesis through ApprovingToolProvider

    func test_approvingProvider_rejectPath_producesSyntheticErrorResult() async throws {
        let coordinator = ToolCallApprovalCoordinator(mode: .alwaysAsk)
        let underlying = MockToolProvider(
            tools: [ToolDefinition(
                name: "delete_file",
                description: "Delete a file",
                inputSchema: ToolInputSchema(properties: [:])
            )]
        )
        let wrapper = ApprovingToolProvider(underlying: underlying, coordinator: coordinator)
        let call = makeCall(name: "delete_file")

        let execTask = Task { try await wrapper.execute(call) }
        for _ in 0..<100 {
            if !coordinator.pendingApprovals.isEmpty { break }
            await Task.yield()
        }
        coordinator.resolve(id: call.id, with: .rejected(reason: "User rejected"))

        let result = try await execTask.value
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.toolCallID, call.id)
        XCTAssertEqual(result.content, "User rejected")
        // The underlying provider must never see the call.
        XCTAssertEqual(underlying.receivedCalls.count, 0)
    }

    func test_approvingProvider_editPath_passesEditedArgumentsToUnderlying() async throws {
        let coordinator = ToolCallApprovalCoordinator(mode: .alwaysAsk)
        let underlying = MockToolProvider(
            tools: [ToolDefinition(
                name: "send_email",
                description: "Send",
                inputSchema: ToolInputSchema(properties: [:])
            )],
            results: ["send_email": ToolResult(toolCallID: "", content: "sent")]
        )
        let wrapper = ApprovingToolProvider(underlying: underlying, coordinator: coordinator)
        let call = makeCall(name: "send_email", arguments: #"{"to":"old@example.com"}"#)

        let execTask = Task { try await wrapper.execute(call) }
        for _ in 0..<100 {
            if !coordinator.pendingApprovals.isEmpty { break }
            await Task.yield()
        }
        coordinator.resolve(
            id: call.id,
            with: .approved(arguments: #"{"to":"new@example.com"}"#)
        )

        let result = try await execTask.value
        XCTAssertEqual(result.content, "sent")
        XCTAssertEqual(underlying.receivedCalls.count, 1)
        XCTAssertEqual(
            underlying.receivedCalls.first?.arguments,
            #"{"to":"new@example.com"}"#
        )
    }

    func test_approvingProvider_autoApproveMode_forwardsWithoutPause() async throws {
        let coordinator = ToolCallApprovalCoordinator(mode: .autoApprove)
        let underlying = MockToolProvider(
            tools: [ToolDefinition(
                name: "get_weather",
                description: "",
                inputSchema: ToolInputSchema(properties: [:])
            )],
            results: ["get_weather": ToolResult(toolCallID: "", content: "sunny")]
        )
        let wrapper = ApprovingToolProvider(underlying: underlying, coordinator: coordinator)
        let call = makeCall(name: "get_weather")

        let result = try await wrapper.execute(call)
        XCTAssertEqual(result.content, "sunny")
        XCTAssertEqual(underlying.receivedCalls.count, 1)
        XCTAssertTrue(coordinator.pendingApprovals.isEmpty)
    }

    // MARK: - Cancellation

    func test_rejectAllPending_releasesAllSuspendedContinuations() async {
        let coordinator = ToolCallApprovalCoordinator(mode: .alwaysAsk)

        let first = Task { await coordinator.requestDecision(for: self.makeCall(id: "c1")) }
        let second = Task { await coordinator.requestDecision(for: self.makeCall(id: "c2")) }

        for _ in 0..<200 {
            if coordinator.pendingApprovals.count == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.pendingApprovals.count, 2)

        coordinator.rejectAllPending(reason: "batch cancel")

        let decisions = await [first.value, second.value]
        for decision in decisions {
            guard case .rejected(let reason) = decision else {
                XCTFail("Expected rejection, got \(decision)")
                return
            }
            XCTAssertEqual(reason, "batch cancel")
        }
        XCTAssertTrue(coordinator.pendingApprovals.isEmpty)
    }

    // MARK: - Service integration

    func test_inferenceService_installsApprovingWrapperOnBackend() async {
        let backend = RecordingToolCallingBackend()
        let service = InferenceService(backend: backend, name: "Mock")
        service.toolApprovalCoordinator.mode = .alwaysAsk

        let underlying = MockToolProvider()
        service.toolProvider = underlying

        XCTAssertTrue(
            backend.lastToolProvider is ApprovingToolProvider,
            "InferenceService should hand the backend a wrapped provider"
        )
    }
}

// MARK: - Test doubles

private final class RecordingToolCallingBackend: InferenceBackend, ToolCallingBackend, ConversationHistoryReceiver, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false

    var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )
    }

    var lastToolDefinitions: [ToolDefinition]?
    var lastToolProvider: (any ToolProvider)?
    var toolCallObserver: (any ToolCallObserver)?

    func setTools(_ tools: [ToolDefinition]) {
        lastToolDefinitions = tools
    }

    func setToolProvider(_ provider: (any ToolProvider)?) {
        lastToolProvider = provider
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() {}
    func setConversationHistory(_ messages: [(role: String, content: String)]) {}
}

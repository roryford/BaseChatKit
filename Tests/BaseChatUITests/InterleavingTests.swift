import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

// MARK: - Interleaving Tests

/// Tests for interleaved operations: stop-then-resend, session-switch mid-stream,
/// and model-swap mid-generation. These verify that concurrent lifecycle transitions
/// don't corrupt state or leak content across sessions.
@MainActor
final class InterleavingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var slowBackend: SlowMockBackend!
    private var persistence: SwiftDataPersistenceProvider!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        slowBackend = SlowMockBackend(tokenCount: 20, delayMilliseconds: 50)

        let service = InferenceService(backend: slowBackend, name: "SlowMock")
        persistence = SwiftDataPersistenceProvider(modelContext: context)
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence)
    }

    override func tearDown() async throws {
        vm?.stopGeneration()
        vm?.inferenceService.unloadModel()
        vm = nil
        sessionManager = nil
        slowBackend = nil
        persistence = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Test Chat") throws -> ChatSessionRecord {
        let session = try sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        vm.switchToSession(session)
        return session
    }

    /// Full expected output when all 20 tokens complete.
    private var fullOutput: String {
        (0..<20).map { "token\($0) " }.joined()
    }

    // MARK: - Test 1: Stop then immediate resend

    /// Stops mid-generation then immediately sends a second message.
    /// The first assistant reply should be partial; the second should complete fully.
    func test_stopGeneration_thenImmediateResend_completesSecondGeneration() async throws {
        try createAndActivateSession()

        // Start first generation with the slow 20-token stream.
        vm.inputText = "first message"
        let firstTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait until tokens are flowing, then cancel.
        await vm.awaitFirstToken()
        vm.stopGeneration()
        await firstTask.value

        // Capture partial content before second send.
        let firstAssistantContent = vm.messages.first(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertFalse(firstAssistantContent.isEmpty, "First assistant should have received some tokens before stop")
        XCTAssertNotEqual(firstAssistantContent, fullOutput, "First assistant should be partial, not the full output")

        // Immediately send a second message with a short, fast reply.
        slowBackend.tokensToYield = ["complete", " second", " reply"]
        slowBackend.delayPerToken = .milliseconds(10)

        vm.inputText = "second message"
        await vm.sendMessage()

        // Expect 4 messages: user1, assistant1 (partial), user2, assistant2 (complete).
        XCTAssertEqual(vm.messages.count, 4,
            "Expected user1 + partial-assistant1 + user2 + assistant2, got \(vm.messages.count)")
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[2].role, .user)
        XCTAssertEqual(vm.messages[3].role, .assistant)

        // First assistant: partial (not all 20 tokens).
        XCTAssertNotEqual(vm.messages[1].content, fullOutput,
            "First assistant message should be partial")
        XCTAssertFalse(vm.messages[1].content.isEmpty,
            "First assistant message should not be empty")

        // Second assistant: complete.
        XCTAssertEqual(vm.messages[3].content, "complete second reply",
            "Second assistant message should have the full second reply")

        // Final state.
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after second generation completes")
        XCTAssertEqual(vm.activityPhase, .idle, "activityPhase should be idle after completion")
    }

    // MARK: - Test 2: Session switch during generation — no content leakage

    /// Starts generation on session A, switches to session B mid-stream,
    /// then generates on B. Verifies no tokens from A leak into B.
    func test_sessionSwitch_duringGeneration_noContentLeakage() async throws {
        // Session A: slow 20-token stream with identifiable tokens.
        let sessionA = try createAndActivateSession(title: "Session A")
        slowBackend.tokensToYield = (0..<20).map { "alpha\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

        // Start generation on A.
        vm.inputText = "question for A"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }
        await vm.awaitFirstToken()

        // Create and switch to session B mid-stream.
        let sessionB = try sessionManager.createSession(title: "Session B")
        sessionManager.activeSession = sessionB
        vm.switchToSession(sessionB)

        // Session B should be empty immediately after switching.
        XCTAssertTrue(vm.messages.isEmpty,
            "Session B should have no messages right after switching")
        XCTAssertEqual(vm.activeSession?.id, sessionB.id)

        // Generate a quick reply on B with distinct tokens.
        slowBackend.tokensToYield = ["beta0", " beta1"]
        slowBackend.delayPerToken = .milliseconds(10)

        vm.inputText = "question for B"
        await vm.sendMessage()

        // Wait for the background generation from A to finish.
        await genTask.value

        // Verify B's messages contain no alpha tokens.
        let sessionBMessages = vm.messages
        for msg in sessionBMessages {
            XCTAssertFalse(msg.content.contains("alpha"),
                "Session B must not contain tokens from session A; found: \(msg.content)")
        }

        // Verify we're still on session B.
        XCTAssertEqual(vm.activeSession?.id, sessionB.id,
            "Should remain on session B after A's generation finishes")

        // Verify persistence: session A has its user message.
        let sessionAPersistedMessages = try persistence.fetchMessages(for: sessionA.id)
        XCTAssertTrue(sessionAPersistedMessages.contains { $0.role == .user && $0.content == "question for A" },
            "Session A should have its user message persisted")

        // Verify persistence: session B has a complete user + assistant turn.
        let sessionBPersistedMessages = try persistence.fetchMessages(for: sessionB.id)
        let sessionBUser = sessionBPersistedMessages.filter { $0.role == .user }
        let sessionBAssistant = sessionBPersistedMessages.filter { $0.role == .assistant }
        XCTAssertEqual(sessionBUser.count, 1, "Session B should have 1 user message persisted")
        XCTAssertEqual(sessionBAssistant.count, 1, "Session B should have 1 assistant message persisted")
        XCTAssertEqual(sessionBAssistant.first?.content, "beta0 beta1",
            "Session B assistant should have the complete beta reply")
    }

    // MARK: - Test 3: Model swap during generation

    /// Starts generation, stops it, then triggers a model reload.
    /// Verifies generation is stopped and the new model loads successfully.
    func test_rapidModelSwap_duringGeneration_stopsAndReloads() async throws {
        try createAndActivateSession()

        // Start generation with slow tokens.
        vm.inputText = "Hello"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }
        await vm.awaitFirstToken()

        // Stop generation.
        vm.stopGeneration()
        await genTask.value

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stop")

        // Register a second mock backend via factory and trigger a model load.
        let reloadBackend = MockInferenceBackend()
        reloadBackend.isModelLoaded = false
        vm.inferenceService.registerBackendFactory { _ in reloadBackend }

        let modelInfo = ModelInfo(
            name: "ReloadedModel",
            fileName: "reloaded.gguf",
            url: URL(fileURLWithPath: "/tmp/reloaded.gguf"),
            fileSize: 0,
            modelType: .gguf
        )
        vm.selectedModel = modelInfo
        vm.dispatchSelectedLoad()

        // Wait for loading to complete.
        await vm.awaitGenerating(false, timeout: 3.0)

        // Yield to let the coordinated load task complete.
        let loadDeadline = ContinuousClock.now + .seconds(2)
        while !vm.isModelLoaded && ContinuousClock.now < loadDeadline {
            await Task.yield()
        }

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after model reload")
        XCTAssertTrue(vm.isModelLoaded, "Model should be loaded after reload completes")
    }
}

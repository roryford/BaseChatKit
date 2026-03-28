import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore

// MARK: - Slow Mock Backend

/// A mock backend that yields tokens with a configurable delay, allowing
/// concurrent operations to interleave during tests.
private final class SlowMockInferenceBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities

    var tokensToYield: [String] = ["Hello", " world"]
    var delayPerToken: UInt64 = 50_000_000 // 50ms in nanoseconds
    var shouldThrowOnGenerate: Error? = nil

    init(
        tokenCount: Int = 4,
        delayMilliseconds: UInt64 = 50,
        capabilities: BackendCapabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )
    ) {
        self.capabilities = capabilities
        self.delayPerToken = delayMilliseconds * 1_000_000
        self.tokensToYield = (0..<tokenCount).map { "token\($0) " }
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        if let error = shouldThrowOnGenerate { throw error }
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }

        isGenerating = true
        let tokens = tokensToYield
        let delay = delayPerToken

        return AsyncThrowingStream { [weak self] continuation in
            Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: delay)
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                self?.isGenerating = false
                continuation.finish()
            }
        }
    }

    func stopGeneration() {
        isGenerating = false
    }

    func unloadModel() {
        isModelLoaded = false
        isGenerating = false
    }
}

// MARK: - Concurrency Tests

/// Tests for concurrent access patterns in ChatViewModel and SessionManagerViewModel.
///
/// Uses a slow mock backend with configurable per-token delay so that concurrent
/// operations (rapid sends, session switches, regeneration) can interleave and
/// expose race conditions or state corruption.
@MainActor
final class ConcurrencyTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var slowBackend: SlowMockInferenceBackend!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()

        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        slowBackend = SlowMockInferenceBackend(tokenCount: 4, delayMilliseconds: 50)

        let service = InferenceService(backend: slowBackend, name: "SlowMock")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(modelContext: context)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(modelContext: context)
    }

    override func tearDown() {
        vm = nil
        sessionManager = nil
        slowBackend = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Test Chat") -> ChatSession {
        let session = sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        vm.switchToSession(session)
        return session
    }

    private func fetchMessages(for sessionID: UUID) -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchSessions() -> [ChatSession] {
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Test 1: Rapid Send Messages

    /// Fire-and-forget 5 messages rapidly. Verify no crash, messages are non-empty,
    /// and isGenerating eventually becomes false.
    func test_rapidSendMessages_doesNotCrash() async throws {
        createAndActivateSession()

        // Fire 5 sends as concurrent tasks without awaiting each one.
        var tasks: [Task<Void, Never>] = []
        for i in 0..<5 {
            vm.inputText = "Rapid message \(i)"
            let task = Task { @MainActor in
                await self.vm.sendMessage()
            }
            tasks.append(task)
        }

        // Wait for all tasks to complete.
        for task in tasks {
            await task.value
        }

        // Allow any remaining MainActor work to settle.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify: no crash (we got here), messages are non-empty, generation finished.
        XCTAssertFalse(vm.messages.isEmpty, "Messages should be non-empty after rapid sends")
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after all tasks complete")
    }

    // MARK: - Test 2: Send While Generating

    /// Start a slow generation, then attempt to send another message while it is
    /// still generating. sendMessage() does NOT guard against isGenerating, so the
    /// second send should also proceed and produce messages.
    func test_sendWhileGenerating_secondSendProceeds() async throws {
        createAndActivateSession()

        // Use a slow backend with many tokens so generation takes a while.
        slowBackend.tokensToYield = (0..<20).map { "tok\($0) " }
        slowBackend.delayPerToken = 50_000_000 // 50ms per token = ~1s total

        // Start first generation.
        vm.inputText = "First message"
        let firstTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait briefly for generation to start.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(vm.isGenerating, "Should be generating after first send")

        // Send a second message while still generating.
        vm.inputText = "Second message"
        let secondTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait for both to complete.
        await firstTask.value
        await secondTask.value

        // Allow settling.
        try await Task.sleep(nanoseconds: 200_000_000)

        // sendMessage() does not guard isGenerating, so both messages should have
        // been sent. We should see user messages for both sends.
        let userMessages = vm.messages.filter { $0.role == .user }
        XCTAssertGreaterThanOrEqual(userMessages.count, 2,
            "Both user messages should be present since sendMessage does not guard isGenerating")
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after all generation completes")
    }

    // MARK: - Test 3: Switch Session During Generation

    /// Start generation on session A with slow tokens. Mid-stream, switch to
    /// session B. Verify session B loads correctly and no messages from session A
    /// leak into session B's view.
    func test_switchSession_duringGeneration_noCorruption() async throws {
        // Set up session A.
        let sessionA = createAndActivateSession(title: "Session A")
        slowBackend.tokensToYield = (0..<20).map { "alphaToken\($0) " }
        slowBackend.delayPerToken = 50_000_000

        // Pre-populate session B with a known message using a fast backend.
        let sessionB = sessionManager.createSession(title: "Session B")

        // Start generation on session A.
        vm.inputText = "Alpha question"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait for generation to start streaming.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(vm.isGenerating, "Should be generating on session A")

        // Switch to session B mid-generation.
        sessionManager.activeSession = sessionB
        vm.switchToSession(sessionB)

        // Session B should have no messages (it was freshly created).
        XCTAssertTrue(vm.messages.isEmpty,
            "Session B should have no messages")
        XCTAssertEqual(vm.activeSession?.id, sessionB.id,
            "Active session should be session B")

        // Verify no session A messages appear in session B's view.
        let sessionBHasAlpha = vm.messages.contains { $0.content.contains("alpha") }
        XCTAssertFalse(sessionBHasAlpha,
            "No messages from session A should leak into session B's view")

        // Wait for the background generation to finish.
        await genTask.value

        // After generation completes, session B should still be clean.
        // Re-check: the view should still show session B's messages.
        let currentSessionID = vm.activeSession?.id
        XCTAssertEqual(currentSessionID, sessionB.id,
            "Should still be on session B after generation finishes")

        // Session A's messages should be in the database.
        let sessionAMessages = fetchMessages(for: sessionA.id)
        XCTAssertTrue(sessionAMessages.contains { $0.role == .user && $0.content == "Alpha question" },
            "Session A should have the user message persisted")
    }

    // MARK: - Test 4: Multiple Concurrent Session Creation

    /// Create 10 sessions concurrently and verify all are persisted in the database.
    func test_multipleSessionCreation_concurrent_allPersisted() async throws {
        var tasks: [Task<Void, Never>] = []

        for i in 0..<10 {
            let task = Task { @MainActor in
                _ = self.sessionManager.createSession(title: "Concurrent Session \(i)")
            }
            tasks.append(task)
        }

        // Wait for all tasks to complete.
        for task in tasks {
            await task.value
        }

        let allSessions = fetchSessions()
        XCTAssertEqual(allSessions.count, 10,
            "All 10 concurrently created sessions should be persisted in the database")

        // Verify each session has a unique title.
        let titles = Set(allSessions.map(\.title))
        XCTAssertEqual(titles.count, 10, "All sessions should have unique titles")
    }

    // MARK: - Test 5: Regenerate While Generating Is Guarded

    /// Start generation, then call regenerateLastResponse() while still generating.
    /// regenerateLastResponse() guards with `guard !isGenerating else { return }`,
    /// so the regeneration should be silently skipped.
    func test_regenerateWhileGenerating_isGuarded() async throws {
        createAndActivateSession()

        slowBackend.tokensToYield = (0..<20).map { "tok\($0) " }
        slowBackend.delayPerToken = 50_000_000

        // Send initial message to start generation.
        vm.inputText = "Initial question"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait for generation to start.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(vm.isGenerating, "Should be generating")

        // Capture message count before regenerate attempt.
        let messageCountBefore = vm.messages.count

        // Attempt regeneration while generating -- should be silently skipped.
        await vm.regenerateLastResponse()

        // Message count should not change because regenerate was guarded.
        XCTAssertEqual(vm.messages.count, messageCountBefore,
            "regenerateLastResponse should be a no-op while isGenerating is true")

        // Wait for original generation to complete.
        await genTask.value

        // Allow settling.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after generation completes")

        // Now regeneration should work.
        slowBackend.tokensToYield = ["regenerated"]
        slowBackend.delayPerToken = 0
        await vm.regenerateLastResponse()

        let lastAssistant = vm.messages.last { $0.role == .assistant }
        XCTAssertEqual(lastAssistant?.content, "regenerated",
            "regenerateLastResponse should work after generation finishes")
    }
}

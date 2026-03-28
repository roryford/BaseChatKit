import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore

// MARK: - Slow Mock Backend

/// A mock backend that yields tokens with configurable delays, enabling
/// cancellation to be tested mid-stream.
private final class SlowMockBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded = true
    var isGenerating = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var tokensToYield: [String] = []
    var delayPerToken: Duration = .milliseconds(50)

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        isGenerating = true
        let tokens = tokensToYield
        let delay = delayPerToken

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                for token in tokens {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: delay)
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

// MARK: - Cancellation Tests

@MainActor
final class CancellationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var slowBackend: SlowMockBackend!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()

        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        slowBackend = SlowMockBackend()
        slowBackend.tokensToYield = (0..<20).map { "t\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

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

    /// The full expected output when all 20 tokens are yielded.
    private var fullOutput: String {
        (0..<20).map { "t\($0) " }.joined()
    }

    // MARK: - Tests

    func test_stopGeneration_midStream_stopsTokenFlow() async throws {
        createAndActivateSession()

        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }
        try await Task.sleep(for: .milliseconds(150))
        vm.stopGeneration()
        await sendTask.value

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stopping")

        // We should have user + assistant (partial)
        XCTAssertEqual(vm.messages.count, 2, "Should have user message and partial assistant message")
        let assistantContent = vm.messages[1].content
        XCTAssertFalse(assistantContent.isEmpty, "Assistant should have received some tokens")
        XCTAssertNotEqual(assistantContent, fullOutput, "Should not have received all tokens")
    }

    func test_stopGeneration_preservesPartialContent() async throws {
        createAndActivateSession()

        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }
        try await Task.sleep(for: .milliseconds(150))
        vm.stopGeneration()
        await sendTask.value

        XCTAssertEqual(vm.messages.count, 2)

        let assistantMessage = vm.messages[1]
        XCTAssertEqual(assistantMessage.role, .assistant)
        XCTAssertFalse(assistantMessage.content.isEmpty, "Partial content should be preserved")
        XCTAssertNotEqual(assistantMessage.content, fullOutput, "Content should differ from full output")
    }

    func test_stopGeneration_thenSendAgain_works() async throws {
        createAndActivateSession()

        // First message: stop mid-generation
        vm.inputText = "First message"
        let sendTask1 = Task { await vm.sendMessage() }
        try await Task.sleep(for: .milliseconds(150))
        vm.stopGeneration()
        await sendTask1.value

        XCTAssertEqual(vm.messages.count, 2, "Should have user1 + partial assistant1")
        XCTAssertFalse(vm.isGenerating)

        // Second message: let it complete fully
        slowBackend.tokensToYield = ["Complete", " response"]
        slowBackend.delayPerToken = .milliseconds(10)
        vm.inputText = "Second message"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 4, "Should have user1 + partial_assistant1 + user2 + assistant2")
        XCTAssertEqual(vm.messages[2].role, .user)
        XCTAssertEqual(vm.messages[2].content, "Second message")
        XCTAssertEqual(vm.messages[3].role, .assistant)
        XCTAssertEqual(vm.messages[3].content, "Complete response")
        XCTAssertFalse(vm.isGenerating)
    }

    func test_clearChat_duringGeneration_stopsAndClears() async throws {
        createAndActivateSession()

        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }
        try await Task.sleep(for: .milliseconds(150))
        vm.clearChat()
        await sendTask.value

        XCTAssertTrue(vm.messages.isEmpty, "Messages should be empty after clearChat")
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after clearChat")
    }

    func test_isGenerating_falseAfterCompletion() async {
        createAndActivateSession()

        slowBackend.tokensToYield = ["a", "b", "c"]
        slowBackend.delayPerToken = .milliseconds(10)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after generation completes")
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[1].content, "abc")
    }
}

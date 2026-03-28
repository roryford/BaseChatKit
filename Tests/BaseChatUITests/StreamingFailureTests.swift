import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore

// MARK: - Enhanced Mock Backends

/// A mock backend that yields some tokens then throws an error mid-stream.
private final class MidStreamErrorBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var tokensBeforeError: [String]
    var errorToThrow: Error

    init(tokensBeforeError: [String], errorToThrow: Error) {
        self.tokensBeforeError = tokensBeforeError
        self.errorToThrow = errorToThrow
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> AsyncThrowingStream<String, Error> {
        let tokens = tokensBeforeError
        let error = errorToThrow
        isGenerating = true
        return AsyncThrowingStream { [weak self] continuation in
            Task {
                for token in tokens {
                    continuation.yield(token)
                }
                self?.isGenerating = false
                continuation.finish(throwing: error)
            }
        }
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false; isGenerating = false }
}

/// A mock backend that yields a configurable list of tokens without errors.
private final class ConfigurableTokenBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var tokensToYield: [String]

    init(tokensToYield: [String]) {
        self.tokensToYield = tokensToYield
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> AsyncThrowingStream<String, Error> {
        let tokens = tokensToYield
        isGenerating = true
        return AsyncThrowingStream { [weak self] continuation in
            Task {
                for token in tokens {
                    continuation.yield(token)
                }
                self?.isGenerating = false
                continuation.finish()
            }
        }
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false; isGenerating = false }
}

// MARK: - Tests

@MainActor
final class StreamingFailureTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sessionManager: SessionManagerViewModel!

    override func setUp() {
        super.setUp()
        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        sessionManager = SessionManagerViewModel()
        sessionManager.configure(modelContext: context)
    }

    override func tearDown() {
        sessionManager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeViewModel(backend: any InferenceBackend, name: String = "MockTest") -> ChatViewModel {
        let service = InferenceService(backend: backend, name: name)
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(modelContext: context)
        return vm
    }

    @discardableResult
    private func createAndActivateSession(vm: ChatViewModel, title: String = "Test Chat") -> ChatSession {
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

    // MARK: - 1. Mid-stream error preserves partial content

    func test_streamError_midStream_preservesPartialContent() async {
        let backend = MidStreamErrorBackend(
            tokensBeforeError: ["Hello", " world"],
            errorToThrow: InferenceError.inferenceFailure("Simulated mid-stream failure")
        )
        let vm = makeViewModel(backend: backend)
        let session = createAndActivateSession(vm: vm)

        vm.inputText = "Say hello"
        await vm.sendMessage()

        // Error message should be set
        XCTAssertNotNil(vm.errorMessage, "Error message should be set after mid-stream failure")

        // Assistant message should preserve partial content
        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Assistant message with partial content should remain")
        XCTAssertEqual(assistantMessages.first?.content, "Hello world", "Partial content should be preserved")

        // User message should still be in the database
        let dbMessages = fetchMessages(for: session.id)
        let userMessages = dbMessages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1, "User message should still be persisted")
        XCTAssertEqual(userMessages.first?.content, "Say hello")
    }

    // MARK: - 2. Mid-stream error sets error message

    func test_streamError_midStream_setsErrorMessage() async {
        let backend = MidStreamErrorBackend(
            tokensBeforeError: ["Hello", " world"],
            errorToThrow: InferenceError.inferenceFailure("Simulated mid-stream failure")
        )
        let vm = makeViewModel(backend: backend)
        createAndActivateSession(vm: vm)

        vm.inputText = "Say hello"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(
            vm.errorMessage?.contains("Generation failed") == true,
            "Error message should contain 'Generation failed', got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - 3. Empty stream removes assistant placeholder

    func test_emptyStream_removesAssistantPlaceholder() async {
        let backend = ConfigurableTokenBackend(tokensToYield: [])
        let vm = makeViewModel(backend: backend)
        createAndActivateSession(vm: vm)

        vm.inputText = "Say something"
        await vm.sendMessage()

        // Only user message should remain
        XCTAssertEqual(vm.messages.count, 1, "Only user message should remain after empty stream")
        XCTAssertEqual(vm.messages.first?.role, .user, "Remaining message should be the user message")
    }

    // MARK: - 4. Single token stream persists correctly

    func test_singleTokenStream_persistsCorrectly() async {
        let backend = ConfigurableTokenBackend(tokensToYield: ["OK"])
        let vm = makeViewModel(backend: backend)
        let session = createAndActivateSession(vm: vm)

        vm.inputText = "Quick question"
        await vm.sendMessage()

        // Check in-memory
        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.content, "OK")

        // Check database
        let dbMessages = fetchMessages(for: session.id)
        let dbAssistant = dbMessages.filter { $0.role == .assistant }
        XCTAssertEqual(dbAssistant.count, 1, "Assistant message should be persisted to DB")
        XCTAssertEqual(dbAssistant.first?.content, "OK")
    }

    // MARK: - 5. Large token count completes successfully

    func test_largeTokenCount_completesSuccessfully() async {
        let tokens = Array(repeating: "t", count: 1000)
        let backend = ConfigurableTokenBackend(tokensToYield: tokens)
        let vm = makeViewModel(backend: backend)
        createAndActivateSession(vm: vm)

        vm.inputText = "Generate a lot"
        await vm.sendMessage()

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.content.count, 1000, "Should have 1000 characters")
        XCTAssertNil(vm.errorMessage, "No error should occur")
    }

    // MARK: - 6. Unicode tokens are preserved

    func test_streamWithUnicodeTokens_preservesContent() async {
        let backend = ConfigurableTokenBackend(tokensToYield: ["Hello ", "\u{1F30D}", " caf\u{00E9}", " na\u{00EF}ve"])
        let vm = makeViewModel(backend: backend)
        createAndActivateSession(vm: vm)

        vm.inputText = "Unicode test"
        await vm.sendMessage()

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.content, "Hello \u{1F30D} caf\u{00E9} na\u{00EF}ve")
    }
}

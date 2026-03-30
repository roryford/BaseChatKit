import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

/// Integration tests for ChatViewModel with a real in-memory SwiftData store and mock inference backend.
///
/// These tests exercise the full pipeline: send message → stream tokens →
/// persist to SwiftData → verify database state. Unlike the unit tests in
/// `ChatViewModelTests` (which skip persistence because modelContext is nil),
/// these wire up a real `ModelContainer` and verify that messages, sessions,
/// and state survive the full round-trip.
@MainActor
final class ChatViewModelIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var mock: MockInferenceBackend!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()

        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", " from", " the", " assistant"]

        let service = InferenceService(backend: mock, name: "MockE2E")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(modelContext: context)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(modelContext: context)
    }

    override func tearDown() {
        vm = nil
        sessionManager = nil
        mock = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a session, activates it, and returns it.
    @discardableResult
    private func createAndActivateSession(title: String = "Test Chat") -> ChatSessionRecord {
        let session = try! sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        vm.switchToSession(session)
        return session
    }

    /// Fetches all ChatMessages from the database for a given session ID.
    private func fetchMessages(for sessionID: UUID) -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fetches all ChatSessions from the database.
    private func fetchSessions() -> [ChatSession] {
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Full Send → Persist Flow

    func test_sendMessage_persistsUserAndAssistantToDatabase() async {
        let session = createAndActivateSession()

        vm.inputText = "What is Swift?"
        await vm.sendMessage()

        // Verify in-memory state
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].content, "What is Swift?")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].content, "Hello from the assistant")

        // Verify database state — messages should be persisted
        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.count, 2, "Database should have 2 persisted messages")
        XCTAssertEqual(dbMessages[0].role, .user)
        XCTAssertEqual(dbMessages[0].content, "What is Swift?")
        XCTAssertEqual(dbMessages[1].role, .assistant)
        XCTAssertEqual(dbMessages[1].content, "Hello from the assistant")
    }

    // MARK: - Multi-Turn Conversation Persistence

    func test_multiTurnConversation_allMessagesPersisted() async {
        let session = createAndActivateSession()

        // Turn 1
        mock.tokensToYield = ["Reply", " one"]
        vm.inputText = "First question"
        await vm.sendMessage()

        // Turn 2
        mock.tokensToYield = ["Reply", " two"]
        vm.inputText = "Second question"
        await vm.sendMessage()

        // Turn 3
        mock.tokensToYield = ["Reply", " three"]
        vm.inputText = "Third question"
        await vm.sendMessage()

        // Verify database has all 6 messages
        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.count, 6, "Should have 6 messages (3 user + 3 assistant)")

        // Verify order and content
        XCTAssertEqual(dbMessages[0].content, "First question")
        XCTAssertEqual(dbMessages[1].content, "Reply one")
        XCTAssertEqual(dbMessages[2].content, "Second question")
        XCTAssertEqual(dbMessages[3].content, "Reply two")
        XCTAssertEqual(dbMessages[4].content, "Third question")
        XCTAssertEqual(dbMessages[5].content, "Reply three")
    }

    // MARK: - Session Switching Reloads Messages

    func test_switchSession_reloadsMessagesFromDatabase() async {
        // Create session A with messages
        let sessionA = createAndActivateSession(title: "Session A")
        mock.tokensToYield = ["Alpha", " reply"]
        vm.inputText = "Alpha question"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2)

        // Create session B with different messages
        let sessionB = createAndActivateSession(title: "Session B")
        mock.tokensToYield = ["Beta", " reply"]
        vm.inputText = "Beta question"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].content, "Beta question")

        // Switch back to session A — messages should reload from database
        vm.switchToSession(sessionA)

        XCTAssertEqual(vm.messages.count, 2, "Session A should have 2 messages")
        XCTAssertEqual(vm.messages[0].content, "Alpha question", "Should reload session A's messages")
        XCTAssertEqual(vm.messages[1].content, "Alpha reply")

        // Switch to session B — verify its messages
        vm.switchToSession(sessionB)

        XCTAssertEqual(vm.messages.count, 2, "Session B should have 2 messages")
        XCTAssertEqual(vm.messages[0].content, "Beta question", "Should reload session B's messages")
    }

    // MARK: - Clear Chat Deletes from Database

    func test_clearChat_deletesMessagesFromDatabase() async {
        let session = createAndActivateSession()

        mock.tokensToYield = ["Reply"]
        vm.inputText = "Message 1"
        await vm.sendMessage()
        vm.inputText = "Message 2"
        await vm.sendMessage()

        let beforeCount = fetchMessages(for: session.id).count
        XCTAssertEqual(beforeCount, 4, "Should have 4 messages before clearing")

        vm.clearChat()

        // Verify in-memory
        XCTAssertTrue(vm.messages.isEmpty)

        // Verify database
        let afterCount = fetchMessages(for: session.id).count
        XCTAssertEqual(afterCount, 0, "Database should have 0 messages after clearChat")
    }

    // MARK: - Regenerate Persists New Response

    func test_regenerate_deletesOldAndPersistsNewResponse() async {
        let session = createAndActivateSession()

        mock.tokensToYield = ["Original", " response"]
        vm.inputText = "Question"
        await vm.sendMessage()

        let originalMessages = fetchMessages(for: session.id)
        XCTAssertEqual(originalMessages.count, 2)
        let originalAssistantID = originalMessages[1].id

        // Regenerate
        mock.tokensToYield = ["New", " response"]
        await vm.regenerateLastResponse()

        // Verify database
        let newMessages = fetchMessages(for: session.id)
        XCTAssertEqual(newMessages.count, 2, "Should still have 2 messages")
        XCTAssertEqual(newMessages[0].content, "Question", "User message unchanged")
        XCTAssertEqual(newMessages[1].content, "New response", "Assistant message should be regenerated")
        XCTAssertNotEqual(newMessages[1].id, originalAssistantID, "Should be a new message, not the original")
    }

    // MARK: - Edit Message Persists Changes

    func test_editMessage_updatesAndRegeneratesInDatabase() async {
        let session = createAndActivateSession()

        mock.tokensToYield = ["Original", " reply"]
        vm.inputText = "Original question"
        await vm.sendMessage()

        // Edit the user message
        mock.tokensToYield = ["Edited", " reply"]
        let userMessage = vm.messages[0]
        await vm.editMessage(userMessage.id, newContent: "Edited question")

        // Verify database
        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.count, 2)
        XCTAssertEqual(dbMessages[0].content, "Edited question", "User message should be updated in DB")
        XCTAssertEqual(dbMessages[1].content, "Edited reply", "Assistant should be regenerated in DB")
    }

    // MARK: - Session Settings Persistence

    func test_saveSettingsToSession_persistsToDatabase() async {
        let session = createAndActivateSession()

        vm.temperature = 1.5
        vm.topP = 0.8
        vm.repeatPenalty = 1.3
        vm.systemPrompt = "You are a pirate."
        try! vm.saveSettingsToSession()

        // Fetch session from database and verify
        let dbSessions = fetchSessions()
        let dbSession = dbSessions.first { $0.id == session.id }
        XCTAssertNotNil(dbSession)
        XCTAssertEqual(dbSession?.temperature, 1.5)
        XCTAssertEqual(dbSession?.topP, 0.8)
        XCTAssertEqual(dbSession?.repeatPenalty, 1.3)
        XCTAssertEqual(dbSession?.systemPrompt, "You are a pirate.")
    }

    // MARK: - Session Switching Restores Settings

    func test_switchSession_restoresGenerationSettings() async {
        // Session A with custom settings
        createAndActivateSession(title: "Session A")
        vm.temperature = 0.3
        vm.systemPrompt = "Be concise."
        try! vm.saveSettingsToSession()
        let sessionA = vm.activeSession!

        // Session B with different settings
        createAndActivateSession(title: "Session B")
        vm.temperature = 1.8
        vm.systemPrompt = "Be verbose."
        try! vm.saveSettingsToSession()
        let sessionB = vm.activeSession!

        // Switch to A — settings should restore
        vm.switchToSession(sessionA)
        XCTAssertEqual(vm.temperature, 0.3, "Temperature should restore from session A")
        XCTAssertEqual(vm.systemPrompt, "Be concise.", "System prompt should restore from session A")

        // Switch to B — settings should restore
        vm.switchToSession(sessionB)
        XCTAssertEqual(vm.temperature, 1.8, "Temperature should restore from session B")
        XCTAssertEqual(vm.systemPrompt, "Be verbose.", "System prompt should restore from session B")
    }

    // MARK: - Empty Response DB Verification

    /// Verifies that when the backend yields no tokens, no blank assistant
    /// `ChatMessage` record is ever written to the SwiftData store.
    /// The check fetches ALL `ChatMessage` rows (not scoped by session) to
    /// catch any phantom insert that might slip through.
    func test_emptyResponse_neverPersistedToDatabase() async {
        let session = createAndActivateSession()

        mock.tokensToYield = []  // Empty stream — no tokens
        vm.inputText = "Anything"
        await vm.sendMessage()

        // In-memory: only the user message should remain.
        XCTAssertEqual(vm.messages.count, 1,
            "Only the user message should remain in vm.messages after an empty response")
        XCTAssertEqual(vm.messages[0].role, .user)

        // Database: fetch ALL ChatMessage records (not scoped to session) to
        // confirm no blank assistant row was ever inserted.
        let allMessagesDescriptor = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let allDbMessages = (try? context.fetch(allMessagesDescriptor)) ?? []
        XCTAssertEqual(allDbMessages.count, 1,
            "Database should contain exactly 1 message (the user message); no blank assistant row should be persisted")
        XCTAssertEqual(allDbMessages[0].role, .user,
            "The sole persisted message must be the user message, not a blank assistant placeholder")
        XCTAssertEqual(allDbMessages[0].sessionID, session.id,
            "The persisted user message should belong to the active session")
    }

    // MARK: - Empty Generation Removes Placeholder

    func test_emptyGeneration_doesNotPersistPlaceholder() async {
        let session = createAndActivateSession()

        mock.tokensToYield = []  // Empty — no tokens yielded
        vm.inputText = "Question"
        await vm.sendMessage()

        // The assistant placeholder should have been removed
        XCTAssertEqual(vm.messages.count, 1, "Only user message should remain")
        XCTAssertEqual(vm.messages[0].role, .user)

        // Database should only have the user message
        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.count, 1, "Database should only have 1 message (user)")
        XCTAssertEqual(dbMessages[0].role, .user)
    }

    // MARK: - Generation Error Does Not Corrupt Database

    func test_generationError_userMessageStillPersisted() async {
        let session = createAndActivateSession()

        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("Simulated failure")
        vm.inputText = "Question before error"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "Error should be set")

        // User message should still be in the database
        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.count, 1, "User message should still be persisted despite generation error")
        XCTAssertEqual(dbMessages[0].content, "Question before error")
    }

    // MARK: - Context Estimation Updates After Messages

    func test_contextEstimate_updatesAfterSendAndClear() async {
        createAndActivateSession()

        let baselineTokens = vm.contextUsedTokens

        mock.tokensToYield = ["This", " is", " a", " response"]
        vm.inputText = "Hello world"
        await vm.sendMessage()

        XCTAssertGreaterThan(vm.contextUsedTokens, baselineTokens, "Tokens should increase after sending")

        vm.clearChat()

        XCTAssertEqual(vm.contextUsedTokens, baselineTokens, "Tokens should return to baseline after clearing")
    }

    // MARK: - Session Creation Through Manager

    func test_sessionManager_createAndDelete_persistsCorrectly() {
        XCTAssertTrue(fetchSessions().isEmpty, "Should start with no sessions")

        let session = try! sessionManager.createSession(title: "My Chat")
        XCTAssertEqual(fetchSessions().count, 1)
        XCTAssertEqual(fetchSessions().first?.title, "My Chat")

        sessionManager.deleteSession(session)
        XCTAssertTrue(fetchSessions().isEmpty, "Session should be deleted from database")
    }

    // MARK: - Delete Session Cascades to Messages

    func test_deleteSession_removesAllSessionMessages() async {
        let session = createAndActivateSession()

        mock.tokensToYield = ["Reply"]
        vm.inputText = "Msg 1"
        await vm.sendMessage()
        vm.inputText = "Msg 2"
        await vm.sendMessage()

        XCTAssertEqual(fetchMessages(for: session.id).count, 4)

        sessionManager.deleteSession(session)

        XCTAssertEqual(fetchMessages(for: session.id).count, 0,
                       "All messages should be deleted when session is deleted")
    }

    // MARK: - Auto-Title Generation

    func test_autoTitle_setsSessionTitleFromFirstMessage() async {
        let session = createAndActivateSession()

        // Wire up the onFirstMessage callback like the real app does
        vm.onFirstMessage = { [weak self] session, firstMessage in
            self?.sessionManager.autoGenerateTitle(for: session, firstMessage: firstMessage)
        }

        XCTAssertEqual(session.title, "Test Chat")

        // The session title is "Test Chat", not "New Chat", so autoGenerateTitle won't fire.
        // Create a fresh session with default title to test auto-title.
        let newSession = try! sessionManager.createSession()  // Default title: "New Chat"
        sessionManager.activeSession = newSession
        vm.switchToSession(newSession)

        mock.tokensToYield = ["Reply"]
        vm.inputText = "What is the meaning of life?"
        await vm.sendMessage()

        // Re-fetch from the session manager since ChatSessionRecord is a value type
        let updatedSession = sessionManager.sessions.first { $0.id == newSession.id }
        XCTAssertNotEqual(updatedSession?.title, "New Chat", "Title should be auto-generated")
        XCTAssertTrue(updatedSession?.title.contains("What is the meaning of life") == true,
                      "Title should be derived from first message, got: \(updatedSession?.title ?? "nil")")
    }

    // MARK: - Export After Persistence

    func test_exportChat_includesPersistedMessages() async {
        createAndActivateSession(title: "Export Test")

        mock.tokensToYield = ["The", " answer"]
        vm.inputText = "Tell me something"
        await vm.sendMessage()

        let markdown = vm.exportChat(format: .markdown)

        XCTAssertTrue(markdown.contains("Tell me something"), "Export should include user message")
        XCTAssertTrue(markdown.contains("The answer"), "Export should include assistant message")
    }

    // MARK: - Save State Persists Pending Changes

    func test_saveState_flushesPendingChanges() async {
        createAndActivateSession()

        mock.tokensToYield = ["Reply"]
        vm.inputText = "Question"
        await vm.sendMessage()

        // Modify session settings and save
        vm.temperature = 0.1
        try! vm.saveSettingsToSession()

        vm.saveState()

        XCTAssertEqual(vm.activeSession?.temperature, 0.1, "saveState should flush pending changes")
    }
}

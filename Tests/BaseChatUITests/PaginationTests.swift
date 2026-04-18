@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatCore
import BaseChatInference
import BaseChatTestSupport

/// Tests for message pagination: loadMessages pages, loadOlderMessages prepend,
/// hasOlderMessages heuristic, and guard against concurrent loads.
@MainActor
final class PaginationTests: XCTestCase {

    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!
    private var stack: InMemoryPersistenceHarness.Stack!
    private var persistence: ErrorInjectingPersistenceProvider!

    override func setUp() async throws {
        try await super.setUp()

        mock = MockInferenceBackend()
        mock.isModelLoaded = true

        let service = InferenceService(backend: mock, name: "MockPagination")
        vm = ChatViewModel(inferenceService: service)

        stack = try InMemoryPersistenceHarness.make()
        persistence = ErrorInjectingPersistenceProvider(wrapping: stack.provider)
        vm.configure(persistence: persistence)
    }

    override func tearDown() async throws {
        vm = nil
        mock = nil
        persistence = nil
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeSession() -> ChatSessionRecord {
        let session = ChatSessionRecord(title: "Pagination Test")
        try! persistence.insertSession(session)
        vm.switchToSession(session)
        return session
    }

    /// Inserts `count` messages with sequential timestamps starting from `baseTime`.
    @discardableResult
    private func insertMessages(
        count: Int,
        sessionID: UUID,
        baseTime: Date = Date(timeIntervalSince1970: 1000)
    ) -> [ChatMessageRecord] {
        var records: [ChatMessageRecord] = []
        for i in 0..<count {
            let msg = ChatMessageRecord(
                role: i % 2 == 0 ? .user : .assistant,
                content: "Message \(i)",
                timestamp: baseTime.addingTimeInterval(Double(i)),
                sessionID: sessionID
            )
            try! persistence.insertMessage(msg)
            records.append(msg)
        }
        return records
    }

    // MARK: - loadMessages

    func test_loadMessages_loadsRecentPage() {
        let session = makeSession()
        let msgs = insertMessages(count: 10, sessionID: session.id)

        vm.loadMessages()

        XCTAssertEqual(vm.messages.count, 10)
        XCTAssertEqual(vm.messages.first?.content, msgs.first?.content)
        XCTAssertEqual(vm.messages.last?.content, msgs.last?.content)
        XCTAssertFalse(vm.hasOlderMessages, "Fewer than pageSize messages means no older messages")
    }

    func test_loadMessages_setsHasOlderMessages_whenFullPage() {
        let session = makeSession()
        insertMessages(count: ChatViewModel.messagePageSize, sessionID: session.id)

        vm.loadMessages()

        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)
        XCTAssertTrue(vm.hasOlderMessages, "Full page should indicate older messages may exist")
    }

    func test_loadMessages_setsHasOlderMessages_whenMoreThanPageSize() {
        let session = makeSession()
        let totalCount = ChatViewModel.messagePageSize + 20
        insertMessages(count: totalCount, sessionID: session.id)

        vm.loadMessages()

        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)
        XCTAssertTrue(vm.hasOlderMessages)
        // Verify we got the most recent messages, not the oldest.
        XCTAssertEqual(vm.messages.last?.content, "Message \(totalCount - 1)")
    }

    func test_loadMessages_withNoSession_clearsState() {
        vm.activeSession = nil
        vm.messages = [ChatMessageRecord(role: .user, content: "stale", sessionID: UUID())]
        vm.hasOlderMessages = true

        vm.loadMessages()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.hasOlderMessages)
    }

    // MARK: - loadOlderMessages

    func test_loadOlderMessages_prependsOlderPage() {
        let session = makeSession()
        let totalCount = ChatViewModel.messagePageSize + 20
        let msgs = insertMessages(count: totalCount, sessionID: session.id)

        vm.loadMessages()
        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)

        let anchorID = vm.loadOlderMessages()

        XCTAssertEqual(vm.messages.count, totalCount)
        // Anchor should be the first message from the initial page (index 20 overall).
        XCTAssertEqual(anchorID, msgs[20].id, "Anchor should be the message that was first before prepend")
        XCTAssertEqual(vm.messages.first?.content, "Message 0")
    }

    func test_loadOlderMessages_returnsNil_whenNoOlderMessages() {
        makeSession()

        let anchorID = vm.loadOlderMessages()
        XCTAssertNil(anchorID, "Should return nil when hasOlderMessages is false")
    }

    func test_loadOlderMessages_setsHasOlderToFalse_whenPartialPage() {
        let session = makeSession()
        let totalCount = ChatViewModel.messagePageSize + 10
        insertMessages(count: totalCount, sessionID: session.id)

        vm.loadMessages()
        XCTAssertTrue(vm.hasOlderMessages)

        vm.loadOlderMessages()

        // Only 10 older messages were loaded, which is less than pageSize.
        XCTAssertFalse(vm.hasOlderMessages, "Partial page means no more older messages")
    }

    func test_loadOlderMessages_setsHasOlderToFalse_whenFetchReturnsEmpty() {
        let session = makeSession()
        // Insert exactly messagePageSize -- heuristic says there may be more.
        insertMessages(count: ChatViewModel.messagePageSize, sessionID: session.id)

        vm.loadMessages()
        XCTAssertTrue(vm.hasOlderMessages)

        vm.loadOlderMessages()

        XCTAssertFalse(vm.hasOlderMessages)
    }

    func test_loadOlderMessages_guardsAgainstConcurrentLoads() {
        let session = makeSession()
        let totalCount = ChatViewModel.messagePageSize + 20
        insertMessages(count: totalCount, sessionID: session.id)

        vm.loadMessages()

        // Simulate isLoadingOlderMessages being true.
        vm.isLoadingOlderMessages = true
        let anchorID = vm.loadOlderMessages()
        XCTAssertNil(anchorID, "Should not load while another load is in progress")
        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize, "Message count should not change")

        vm.isLoadingOlderMessages = false
    }

    func test_loadOlderMessages_resetsLoadingFlag() {
        let session = makeSession()
        let totalCount = ChatViewModel.messagePageSize + 20
        insertMessages(count: totalCount, sessionID: session.id)

        vm.loadMessages()
        vm.loadOlderMessages()

        XCTAssertFalse(vm.isLoadingOlderMessages, "Loading flag should be cleared after load completes")
    }

    // MARK: - clearChat resets pagination state

    func test_clearChat_resetsHasOlderMessages() {
        let session = makeSession()
        insertMessages(count: ChatViewModel.messagePageSize + 10, sessionID: session.id)

        vm.loadMessages()
        XCTAssertTrue(vm.hasOlderMessages)

        vm.clearChat()

        XCTAssertFalse(vm.hasOlderMessages)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    // MARK: - Mock call tracking

    func test_loadMessages_callsFetchRecentMessages() {
        let session = makeSession()
        insertMessages(count: 5, sessionID: session.id)

        // Reset count after switchToSession's loadMessages call.
        persistence.fetchRecentMessagesCallCount = 0

        vm.loadMessages()

        XCTAssertEqual(persistence.fetchRecentMessagesCallCount, 1)
    }

    func test_loadOlderMessages_callsFetchMessagesBefore() {
        let session = makeSession()
        insertMessages(count: ChatViewModel.messagePageSize + 10, sessionID: session.id)

        vm.loadMessages()
        persistence.fetchMessagesBeforeCallCount = 0

        vm.loadOlderMessages()

        XCTAssertEqual(persistence.fetchMessagesBeforeCallCount, 1)
    }
}

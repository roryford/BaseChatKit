import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

@MainActor
final class SessionManagerViewModelTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        vm = SessionManagerViewModel()
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        vm = nil
        try await super.tearDown()
    }

    // MARK: - Create

    @MainActor
    func test_createSession_insertsIntoContext() {
        let session = try! vm.createSession(title: "Test Session")

        XCTAssertEqual(session.title, "Test Session")
        XCTAssertEqual(vm.sessions.count, 1)
        XCTAssertEqual(vm.sessions.first?.id, session.id)
    }

    @MainActor
    func test_createSession_defaultTitle() {
        let session = try! vm.createSession()
        XCTAssertEqual(session.title, "New Chat")
    }

    // MARK: - Delete

    @MainActor
    func test_deleteSession_removesSession() {
        let session = try! vm.createSession(title: "To Delete")
        XCTAssertEqual(vm.sessions.count, 1)

        vm.deleteSession(session)

        XCTAssertEqual(vm.sessions.count, 0)
    }

    @MainActor
    func test_deleteSession_removesAssociatedMessages() {
        let session = try! vm.createSession()

        // Insert messages for this session
        let msg1 = ChatMessage(role: .user, content: "Hello", sessionID: session.id)
        let msg2 = ChatMessage(role: .assistant, content: "Hi", sessionID: session.id)
        context.insert(msg1)
        context.insert(msg2)
        try? context.save()

        vm.deleteSession(session)

        // Verify messages are also deleted
        let sessionID = session.id
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let remaining = try? context.fetch(descriptor)
        XCTAssertEqual(remaining?.count ?? 0, 0, "Messages should be deleted with session")
    }

    @MainActor
    func test_deleteSession_clearsActiveIfDeleted() {
        let session = try! vm.createSession()
        vm.activeSession = session

        vm.deleteSession(session)

        XCTAssertNil(vm.activeSession)
    }

    // MARK: - Rename

    @MainActor
    func test_renameSession_updatesTitle() {
        let session = try! vm.createSession(title: "Original")

        vm.renameSession(session, title: "Renamed")

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Renamed")
    }

    // MARK: - Auto-Generate Title

    @MainActor
    func test_autoGenerateTitle_setsFromFirstMessage() {
        let session = try! vm.createSession()
        XCTAssertEqual(session.title, "New Chat")

        vm.autoGenerateTitle(for: session, firstMessage: "Tell me about dragons")

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Tell me about dragons")
    }

    @MainActor
    func test_autoGenerateTitle_truncatesAtWordBoundary() {
        let session = try! vm.createSession()
        let longMessage = "This is a really long message that should be truncated at a word boundary because it exceeds fifty characters"

        vm.autoGenerateTitle(for: session, firstMessage: longMessage)

        let updated = vm.sessions.first { $0.id == session.id }!
        XCTAssertTrue(updated.title.count <= 53, "Title should be truncated (50 chars + '...')")
        XCTAssertTrue(updated.title.hasSuffix("..."), "Truncated title should end with ...")
        XCTAssertFalse(updated.title.contains("characters"), "Should truncate before 'characters'")
    }

    @MainActor
    func test_autoGenerateTitle_skipsIfAlreadyNamed() {
        let session = try! vm.createSession(title: "Custom Title")

        vm.autoGenerateTitle(for: session, firstMessage: "This should be ignored")

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Custom Title",
                       "Should not overwrite a user-set title")
    }

    @MainActor
    func test_autoGenerateTitle_handlesEmptyMessage() {
        let session = try! vm.createSession()

        vm.autoGenerateTitle(for: session, firstMessage: "   ")

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "New Chat",
                       "Should not set empty title")
    }

    // MARK: - Sort Order

    @MainActor
    func test_sessions_sortedByUpdatedAtDescending() {
        _ = try! vm.createSession(title: "Oldest")
        _ = try! vm.createSession(title: "Middle")
        _ = try! vm.createSession(title: "Newest")

        vm.loadSessions()

        XCTAssertEqual(vm.sessions.count, 3)
        XCTAssertEqual(vm.sessions[0].title, "Newest")
        XCTAssertEqual(vm.sessions[1].title, "Middle")
        XCTAssertEqual(vm.sessions[2].title, "Oldest")
    }
}

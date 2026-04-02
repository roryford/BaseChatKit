import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

@MainActor
final class PinMessageTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!

    override func setUp() async throws {
        try await super.setUp()

        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Reply"]

        let service = InferenceService(backend: mock, name: "MockPin")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(modelContext: context)
    }

    override func tearDown() async throws {
        vm = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    @discardableResult
    private func createSession(title: String = "Pin Test") -> ChatSessionRecord {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        let record = session.toRecord()
        vm.switchToSession(record)
        return record
    }

    private func makeMessageID(content: String = "Hello") -> UUID {
        let sessionID = vm.activeSession!.id
        let msg = ChatMessageRecord(role: .user, content: content, sessionID: sessionID)
        vm.messages.append(msg)
        return msg.id
    }

    // MARK: - Tests

    func test_pinMessage_addsToSet() {
        createSession()
        let id = makeMessageID()

        vm.pinMessage(id: id)

        XCTAssertTrue(vm.isMessagePinned(id: id),
                      "isMessagePinned should return true after pinMessage")
    }

    func test_unpinMessage_removesFromSet() {
        createSession()
        let id = makeMessageID()

        vm.pinMessage(id: id)
        XCTAssertTrue(vm.isMessagePinned(id: id), "Precondition: message should be pinned")

        vm.unpinMessage(id: id)

        XCTAssertFalse(vm.isMessagePinned(id: id),
                       "isMessagePinned should return false after unpinMessage")
    }

    func test_pinMessage_idempotent() {
        createSession()
        let id = makeMessageID()

        vm.pinMessage(id: id)
        vm.pinMessage(id: id)

        XCTAssertEqual(vm.pinnedMessageIDs.count, 1,
                       "pinnedMessageIDs should contain exactly 1 entry after pinning the same message twice")
    }

    func test_unpin_unpinnedMessage_doesNotCrash() {
        createSession()
        let id = makeMessageID()

        vm.unpinMessage(id: id)

        XCTAssertFalse(vm.isMessagePinned(id: id),
                       "Message should remain unpinned after unpinMessage on a non-pinned message")
    }

    func test_pinMultipleMessages_allPinned() {
        createSession()
        let id1 = makeMessageID(content: "First")
        let id2 = makeMessageID(content: "Second")
        let id3 = makeMessageID(content: "Third")

        vm.pinMessage(id: id1)
        vm.pinMessage(id: id2)
        vm.pinMessage(id: id3)

        XCTAssertTrue(vm.isMessagePinned(id: id1), "msg1 should be pinned")
        XCTAssertTrue(vm.isMessagePinned(id: id2), "msg2 should be pinned")
        XCTAssertTrue(vm.isMessagePinned(id: id3), "msg3 should be pinned")
        XCTAssertEqual(vm.pinnedMessageIDs.count, 3,
                       "All 3 messages should appear in pinnedMessageIDs")
    }

    func test_pinnedState_clearedOnSessionSwitch() {
        createSession(title: "Session A")
        let idA = makeMessageID(content: "Message in A")
        vm.pinMessage(id: idA)
        XCTAssertTrue(vm.isMessagePinned(id: idA), "Precondition: msgA should be pinned in session A")

        let sessionB = ChatSession(title: "Session B")
        context.insert(sessionB)
        try? context.save()
        vm.switchToSession(sessionB.toRecord())

        XCTAssertFalse(vm.pinnedMessageIDs.contains(idA),
                       "Pins from session A should not be visible after switching to session B")
    }
}

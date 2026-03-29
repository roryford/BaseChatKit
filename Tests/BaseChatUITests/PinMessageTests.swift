import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

/// Unit tests for the pin/unpin message API on ChatViewModel.
///
/// These tests call pinMessage/unpinMessage/isMessagePinned directly, constructing
/// ChatMessage objects without going through sendMessage. The focus is on the
/// ViewModel API that the MessageActionMenu buttons invoke.
@MainActor
final class PinMessageTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
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
        mock.tokensToYield = ["Reply"]

        let service = InferenceService(backend: mock, name: "MockPin")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(modelContext: context)
    }

    override func tearDown() {
        vm = nil
        mock = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createSession(title: String = "Pin Test") -> ChatSession {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        vm.switchToSession(session)
        return session
    }

    private func makeMessage(content: String = "Hello") -> ChatMessage {
        let sessionID = vm.activeSession!.id
        return ChatMessage(role: .user, content: content, sessionID: sessionID)
    }

    // MARK: - Tests

    func test_pinMessage_addsToSet() {
        createSession()
        let msg = makeMessage()

        vm.pinMessage(msg)

        XCTAssertTrue(vm.isMessagePinned(msg),
                      "isMessagePinned should return true after pinMessage")
    }

    func test_unpinMessage_removesFromSet() {
        createSession()
        let msg = makeMessage()

        vm.pinMessage(msg)
        XCTAssertTrue(vm.isMessagePinned(msg), "Precondition: message should be pinned")

        vm.unpinMessage(msg)

        XCTAssertFalse(vm.isMessagePinned(msg),
                       "isMessagePinned should return false after unpinMessage")
    }

    func test_pinMessage_idempotent() {
        createSession()
        let msg = makeMessage()

        vm.pinMessage(msg)
        vm.pinMessage(msg)

        XCTAssertEqual(vm.pinnedMessageIDs.count, 1,
                       "pinnedMessageIDs should contain exactly 1 entry after pinning the same message twice")
    }

    func test_unpin_unpinnedMessage_doesNotCrash() {
        createSession()
        let msg = makeMessage()

        // Should not throw or crash — calling unpinMessage on a non-pinned message is safe.
        vm.unpinMessage(msg)

        XCTAssertFalse(vm.isMessagePinned(msg),
                       "Message should remain unpinned after unpinMessage on a non-pinned message")
    }

    func test_pinMultipleMessages_allPinned() {
        createSession()
        let sessionID = vm.activeSession!.id
        let msg1 = ChatMessage(role: .user, content: "First", sessionID: sessionID)
        let msg2 = ChatMessage(role: .assistant, content: "Second", sessionID: sessionID)
        let msg3 = ChatMessage(role: .user, content: "Third", sessionID: sessionID)

        vm.pinMessage(msg1)
        vm.pinMessage(msg2)
        vm.pinMessage(msg3)

        XCTAssertTrue(vm.isMessagePinned(msg1), "msg1 should be pinned")
        XCTAssertTrue(vm.isMessagePinned(msg2), "msg2 should be pinned")
        XCTAssertTrue(vm.isMessagePinned(msg3), "msg3 should be pinned")
        XCTAssertEqual(vm.pinnedMessageIDs.count, 3,
                       "All 3 messages should appear in pinnedMessageIDs")
    }

    func test_pinnedState_clearedOnSessionSwitch() {
        let sessionA = createSession(title: "Session A")
        let msgA = makeMessage(content: "Message in A")
        vm.pinMessage(msgA)
        XCTAssertTrue(vm.isMessagePinned(msgA), "Precondition: msgA should be pinned in session A")

        let sessionB = ChatSession(title: "Session B")
        context.insert(sessionB)
        try? context.save()
        vm.switchToSession(sessionB)

        XCTAssertFalse(vm.pinnedMessageIDs.contains(msgA.id),
                       "Pins from session A should not be visible after switching to session B")
        _ = sessionA  // suppress unused warning
    }
}

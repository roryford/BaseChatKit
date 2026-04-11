@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// ViewModel integration tests for the data that drives the pin indicator in MessageBubbleView.
///
/// Each test targets `isMessagePinned`, `pinMessage`, and `unpinMessage` to confirm that
/// the Boolean value powering the visual indicator is correct across all relevant state
/// transitions, and that pin state is persisted to the active ChatSession.
@MainActor
final class PinnedMessageIndicatorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Reply"]

        let service = InferenceService(backend: mock, name: "MockPin")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        vm = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createSession(title: String = "Pin Test") -> ChatSession {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        vm.switchToSession(session.toRecord())
        return session
    }

    private func makeMessage() -> ChatMessage {
        let sessionID = vm.activeSession!.id
        let message = ChatMessage(role: .user, content: "Test message", sessionID: sessionID)
        vm.messages.append(message.toRecord())
        return message
    }

    // MARK: - Tests

    func test_isMessagePinned_falseBeforePin() {
        createSession()
        let message = makeMessage()

        XCTAssertFalse(vm.isMessagePinned(id: message.id),
                       "A newly created message should not be pinned")
    }

    func test_isMessagePinned_trueAfterPin() {
        createSession()
        let message = makeMessage()

        vm.pinMessage(id: message.id)

        XCTAssertTrue(vm.isMessagePinned(id: message.id),
                      "isMessagePinned should return true after pinMessage")
    }

    func test_isMessagePinned_falseAfterUnpin() {
        createSession()
        let message = makeMessage()

        vm.pinMessage(id: message.id)
        XCTAssertTrue(vm.isMessagePinned(id: message.id), "Precondition: message should be pinned")

        vm.unpinMessage(id: message.id)

        XCTAssertFalse(vm.isMessagePinned(id: message.id),
                       "isMessagePinned should return false after unpinMessage")
    }

    func test_pinnedMessageIDs_persistedToSession() {
        let session = createSession()
        let message = makeMessage()

        vm.pinMessage(id: message.id)

        XCTAssertTrue(session.toRecord().pinnedMessageIDs.contains(message.id),
                      "After pinMessage, the session's pinnedMessageIDs should contain the message's id")
    }

    func test_unpinnedMessage_removedFromSession() {
        let session = createSession()
        let message = makeMessage()

        vm.pinMessage(id: message.id)
        XCTAssertTrue(session.toRecord().pinnedMessageIDs.contains(message.id),
                      "Precondition: session should contain the pinned id")

        vm.unpinMessage(id: message.id)

        XCTAssertFalse(session.toRecord().pinnedMessageIDs.contains(message.id),
                       "After unpinMessage, the session's pinnedMessageIDs should no longer contain the id")
    }
}

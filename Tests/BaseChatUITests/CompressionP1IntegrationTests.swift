import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
import BaseChatTestSupport

@MainActor
final class CompressionP1IntegrationTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!

    override func setUpWithError() throws {
        try super.setUpWithError()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Reply"]

        let service = InferenceService(backend: mock, name: "MockP1Compression")
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

    func test_multiSessionPins_areIsolatedAcrossSwitchesAndPersistence() {
        let sessionA = createSession(title: "A")
        let aMessageID = UUID()
        vm.messages.append(ChatMessageRecord(id: aMessageID, role: .user, content: "A-msg", sessionID: sessionA.id))
        vm.pinMessage(id: aMessageID)
        XCTAssertTrue(vm.pinnedMessageIDs.contains(aMessageID))

        let sessionB = createSession(title: "B")
        let bMessageID = UUID()
        vm.messages.append(ChatMessageRecord(id: bMessageID, role: .user, content: "B-msg", sessionID: sessionB.id))

        XCTAssertFalse(vm.pinnedMessageIDs.contains(aMessageID))

        vm.pinMessage(id: bMessageID)
        XCTAssertTrue(vm.pinnedMessageIDs.contains(bMessageID))
        XCTAssertFalse(vm.pinnedMessageIDs.contains(aMessageID))

        vm.switchToSession(sessionA.toRecord())
        XCTAssertTrue(vm.pinnedMessageIDs.contains(aMessageID))
        XCTAssertFalse(vm.pinnedMessageIDs.contains(bMessageID))

        vm.switchToSession(sessionB.toRecord())
        XCTAssertTrue(vm.pinnedMessageIDs.contains(bMessageID))
        XCTAssertFalse(vm.pinnedMessageIDs.contains(aMessageID))

        let sessions = fetchSessionsByTitle()
        XCTAssertEqual(sessions["A"]?.pinnedMessageIDs, [aMessageID])
        XCTAssertEqual(sessions["B"]?.pinnedMessageIDs, [bMessageID])
    }

    private func createSession(title: String) -> ChatSession {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        vm.switchToSession(session.toRecord())
        return session
    }

    private func fetchSessionsByTitle() -> [String: ChatSession] {
        let descriptor = FetchDescriptor<ChatSession>()
        let sessions = (try? context.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: sessions.map { ($0.title, $0) })
    }
}

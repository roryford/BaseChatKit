import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

@MainActor
final class SessionAutoRenameTests: XCTestCase {

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

    // MARK: - Helpers

    private func makeInferenceService(tokens: [String]) -> InferenceService {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = tokens
        return InferenceService(backend: mock, name: "Mock")
    }

    private func makeThrowingInferenceService() -> InferenceService {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("Mock failure")
        return InferenceService(backend: mock, name: "Mock")
    }

    // MARK: - Tests

    func test_autoRename_updatesSessionTitle() async {
        let session = try! vm.createSession()
        XCTAssertEqual(session.title, "New Chat")

        let service = makeInferenceService(tokens: ["Travel", " Planning", " Tips"])

        await vm.autoRenameSession(session, firstMessage: "How do I plan a trip?", inferenceService: service)

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Travel Planning Tips")
    }

    func test_autoRename_onError_keepsExistingTitle() async {
        let session = try! vm.createSession()
        XCTAssertEqual(session.title, "New Chat")

        let service = makeThrowingInferenceService()

        await vm.autoRenameSession(session, firstMessage: "Tell me about dogs", inferenceService: service)

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "New Chat")
    }

    func test_autoRename_truncatesLongTitle() async {
        let session = try! vm.createSession()

        // 60-character title returned by the mock
        let longTitle = "This Is A Very Long Title That Definitely Exceeds Fifty Char"
        XCTAssertEqual(longTitle.count, 60)

        let service = makeInferenceService(tokens: [longTitle])

        await vm.autoRenameSession(session, firstMessage: "Some question", inferenceService: service)

        let updated = vm.sessions.first { $0.id == session.id }!
        XCTAssertEqual(updated.title.count, 50)
        XCTAssertEqual(updated.title, String(longTitle.prefix(50)))
    }

    func test_autoRename_trimsWhitespace() async {
        let session = try! vm.createSession()

        let service = makeInferenceService(tokens: ["  My Title  \n"])

        await vm.autoRenameSession(session, firstMessage: "What is cooking?", inferenceService: service)

        let updated = vm.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "My Title")
    }
}

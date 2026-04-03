import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

// MARK: - Session Override Tests

@MainActor
final class SessionOverrideTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var mockBackend: MockInferenceBackend!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        mockBackend = MockInferenceBackend()
        mockBackend.isModelLoaded = true
        mockBackend.tokensToYield = ["ok"]

        let service = InferenceService(backend: mockBackend, name: "Mock")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(modelContext: context)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(modelContext: context)
    }

    override func tearDown() async throws {
        vm?.stopGeneration()
        vm?.inferenceService.unloadModel()
        vm = nil
        sessionManager = nil
        mockBackend = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(
        title: String = "Test Chat",
        temperature: Float? = nil,
        topP: Float? = nil,
        repeatPenalty: Float? = nil
    ) -> ChatSessionRecord {
        var session = try! sessionManager.createSession(title: title)
        session.temperature = temperature
        session.topP = topP
        session.repeatPenalty = repeatPenalty
        sessionManager.activeSession = session
        vm.switchToSession(session)
        return session
    }

    private func sendMessage(_ text: String = "Hello") async {
        vm.inputText = text
        await vm.sendMessage()
    }

    // MARK: - Tests

    func test_customOverrides_passedToBackend() async throws {
        createAndActivateSession(
            title: "Custom",
            temperature: 0.3,
            topP: 0.5,
            repeatPenalty: 1.5
        )

        await sendMessage()

        let config = try XCTUnwrap(mockBackend.lastConfig)
        XCTAssertEqual(config.temperature, 0.3, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.repeatPenalty, 1.5, accuracy: 0.001)
    }

    func test_noOverrides_usesDefaults() async throws {
        createAndActivateSession(title: "Default")

        await sendMessage()

        let config = try XCTUnwrap(mockBackend.lastConfig)
        XCTAssertEqual(config.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.9, accuracy: 0.001)
        XCTAssertEqual(config.repeatPenalty, 1.1, accuracy: 0.001)
    }

    func test_switchBackToCustomSession_overridesStillApplied() async throws {
        // Session A: custom overrides
        let sessionA = createAndActivateSession(
            title: "Session A",
            temperature: 0.3,
            topP: 0.5,
            repeatPenalty: 1.5
        )

        await sendMessage("From A first")

        // Session B: defaults
        createAndActivateSession(title: "Session B")

        await sendMessage("From B")

        let defaultConfig = try XCTUnwrap(mockBackend.lastConfig)
        XCTAssertEqual(defaultConfig.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(defaultConfig.topP, 0.9, accuracy: 0.001)
        XCTAssertEqual(defaultConfig.repeatPenalty, 1.1, accuracy: 0.001)

        // Switch back to Session A
        vm.switchToSession(sessionA)

        await sendMessage("From A again")

        let overriddenConfig = try XCTUnwrap(mockBackend.lastConfig)
        XCTAssertEqual(overriddenConfig.temperature, 0.3, accuracy: 0.001)
        XCTAssertEqual(overriddenConfig.topP, 0.5, accuracy: 0.001)
        XCTAssertEqual(overriddenConfig.repeatPenalty, 1.5, accuracy: 0.001)
    }
}

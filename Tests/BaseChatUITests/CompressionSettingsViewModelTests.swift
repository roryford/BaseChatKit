import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
import BaseChatTestSupport

@MainActor
final class CompressionSettingsViewModelTests: XCTestCase {

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

        let service = InferenceService(backend: mock, name: "MockCompression")
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

    // MARK: - test_compressionMode_defaultIsAutomatic

    func test_compressionMode_defaultIsAutomatic() {
        XCTAssertEqual(vm.compressionMode, .automatic,
                       "Fresh ChatViewModel should default to .automatic compression mode")
    }

    // MARK: - test_compressionMode_setBalanced_syncsToOrchestrator

    func test_compressionMode_setBalanced_syncsToOrchestrator() {
        vm.compressionMode = .balanced

        XCTAssertEqual(vm.compressionOrchestrator.mode, .balanced,
                       "Setting compressionMode to .balanced should sync to orchestrator.mode")
    }

    // MARK: - test_compressionMode_setOff_syncsToOrchestrator

    func test_compressionMode_setOff_syncsToOrchestrator() {
        vm.compressionMode = .off

        XCTAssertEqual(vm.compressionOrchestrator.mode, .off,
                       "Setting compressionMode to .off should sync to orchestrator.mode")
    }

    // MARK: - test_compressionMode_allCasesAreAvailable

    func test_compressionMode_allCasesAreAvailable() {
        XCTAssertEqual(CompressionMode.allCases.count, 3,
                       "CompressionMode should have exactly 3 cases")
        XCTAssertTrue(CompressionMode.allCases.contains(.automatic))
        XCTAssertTrue(CompressionMode.allCases.contains(.balanced))
        XCTAssertTrue(CompressionMode.allCases.contains(.off))
    }

    // MARK: - test_compressionMode_displayNameRoundTrip

    func test_compressionMode_displayNameRoundTrip() {
        XCTAssertEqual(CompressionMode.automatic.rawValue, "Automatic")
        XCTAssertEqual(CompressionMode.balanced.rawValue, "Balanced")
        XCTAssertEqual(CompressionMode.off.rawValue, "Off")

        // Verify rawValue round-trips back to the correct case.
        XCTAssertEqual(CompressionMode(rawValue: "Automatic"), .automatic)
        XCTAssertEqual(CompressionMode(rawValue: "Balanced"), .balanced)
        XCTAssertEqual(CompressionMode(rawValue: "Off"), .off)
    }
}

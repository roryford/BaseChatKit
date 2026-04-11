@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests that `ChatViewModel.lastCompressionStats` is correctly nil by default,
/// populated when compression fires, cleared when it does not, and contains
/// reasonable field values after a real compression pass.
@MainActor
final class CompressionStatsDisplayTests: XCTestCase {

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

        let service = InferenceService(backend: mock, name: "MockStatsDisplay")
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
    private func createSession(title: String = "Stats Display Test") -> ChatSession {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        vm.switchToSession(session.toRecord())
        return session
    }

    /// Pre-loads `count` messages of `charCount` characters each into vm.messages,
    /// then sets contextMaxTokens to `contextMax` and compressionMode to .automatic.
    /// Mirrors the setup from `test_compressionFiresAndProducesStats_whenContextIsFull`.
    private func primeForCompression(messageCount: Int = 5, charCount: Int = 80, contextMax: Int = 600) {
        vm.compressionMode = .automatic
        vm.contextMaxTokens = contextMax

        let longContent = String(repeating: "b", count: charCount)
        let sessionID = vm.activeSession!.id
        for _ in 0..<messageCount {
            let msg = ChatMessageRecord(role: .user,
                                  content: longContent,
                                  sessionID: sessionID)
            vm.messages.append(msg)
        }
    }

    // MARK: - Tests

    func test_lastCompressionStats_nilByDefault() {
        createSession()
        XCTAssertNil(vm.lastCompressionStats,
                     "A fresh ChatViewModel should have nil lastCompressionStats")
    }

    func test_lastCompressionStats_populatedAfterCompression() async {
        createSession()
        primeForCompression()

        mock.tokensToYield = ["AssistantReply"]
        vm.inputText = "One more question"
        await vm.sendMessage()

        XCTAssertNotNil(vm.lastCompressionStats,
                        "lastCompressionStats should be non-nil after compression fires")
    }

    func test_lastCompressionStats_clearedOnNextSendWithNoCompression() async {
        createSession()

        // Prime a non-nil value as if a previous compression ran.
        vm.lastCompressionStats = CompressionStats(
            strategy: "extractive",
            originalNodeCount: 10,
            outputMessageCount: 5,
            estimatedTokens: 100,
            compressionRatio: 2.0,
            keywordSurvivalRate: nil
        )
        XCTAssertNotNil(vm.lastCompressionStats, "Precondition: stats should be non-nil before generation")

        // Default context (2048 tokens), no pre-loaded messages — shouldCompress returns false.
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Short message"
        await vm.sendMessage()

        XCTAssertNil(vm.lastCompressionStats,
                     "lastCompressionStats should be nil when compression does not fire")
    }

    func test_compressionStats_fields_areReasonable() async {
        createSession()
        primeForCompression()

        mock.tokensToYield = ["AssistantReply"]
        vm.inputText = "One more question"
        await vm.sendMessage()

        guard let stats = vm.lastCompressionStats else {
            XCTFail("lastCompressionStats must be non-nil after compression fires")
            return
        }

        XCTAssertGreaterThan(stats.compressionRatio, 1.0,
                             "compressionRatio should exceed 1.0 when messages were actually compressed")
        XCTAssertGreaterThan(stats.originalNodeCount, stats.outputMessageCount,
                             "originalNodeCount should exceed outputMessageCount after compression")
        XCTAssertFalse(stats.strategy.isEmpty,
                       "strategy should be a non-empty string")
    }
}

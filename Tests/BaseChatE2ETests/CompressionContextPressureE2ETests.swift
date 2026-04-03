import Testing
import Foundation
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

/// E2E: fill context → compression fires → generation continues → messages persist.
///
/// Uses `CharTokenizer` (1 char = 1 token) with a tiny context window so
/// compression triggers deterministically without real model hardware.
@Suite("Compression Under Context Pressure E2E")
@MainActor
struct CompressionContextPressureE2ETests {

    private let container: ModelContainer
    private let context: ModelContext
    private let mock: MockInferenceBackend
    private let vm: ChatViewModel
    private let sessionManager: SessionManagerViewModel

    init() throws {
        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Compressed", " reply"]

        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        let service = InferenceService(backend: mock, name: "MockE2E")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)
        vm.compressionMode = .automatic

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence)
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Compression Test") throws -> ChatSessionRecord {
        let session = try sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        vm.switchToSession(session)
        return session
    }

    private func fetchMessages(for sessionID: UUID) -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fills the conversation with messages to push token usage above the compression threshold.
    /// HeuristicTokenizer: 4 chars = 1 token.
    /// contextSize=600, available = 600 - 512 = 88, threshold at 75% = 66 tokens = 264 chars.
    /// 5 user+assistant pairs × ~160 chars each = ~1600 chars = ~400 tokens → well above.
    private func fillContext() async {
        vm.contextMaxTokens = 600

        for i in 0..<5 {
            mock.tokensToYield = [String(repeating: "r", count: 160)]
            vm.inputText = "Message \(i): " + String(repeating: "x", count: 146)
            await vm.sendMessage()
        }
    }

    // MARK: - Tests

    @Test("Full flow: compression fires, generation continues, reply persisted")
    func fullFlow_compressionFires_generationContinues() async throws {
        let session = try createAndActivateSession()
        await fillContext()

        // Next message should trigger compression
        mock.tokensToYield = ["Final", " answer"]
        vm.inputText = "Trigger compression"
        await vm.sendMessage()

        // Compression should have fired
        #expect(vm.lastCompressionStats != nil, "Compression should have fired")

        // Generation should have completed
        let lastAssistant = vm.messages.last { $0.role == .assistant }
        #expect(lastAssistant != nil)
        #expect(lastAssistant?.content.contains("Final") == true)

        // Messages should be persisted
        let dbMessages = fetchMessages(for: session.id)
        #expect(!dbMessages.isEmpty)
        #expect(dbMessages.last?.role == .assistant)
    }

    @Test("Compression stats contain meaningful values")
    func compressionStats_haveMeaningfulValues() async throws {
        try createAndActivateSession()
        await fillContext()

        mock.tokensToYield = ["Post", " compression"]
        vm.inputText = "After filling"
        await vm.sendMessage()

        guard let stats = vm.lastCompressionStats else {
            Issue.record("Expected compression stats to be populated")
            return
        }

        #expect(stats.originalNodeCount > 0)
        #expect(stats.outputMessageCount > 0)
        #expect(stats.compressionRatio >= 1.0, "Ratio should be >= 1.0 (original / compressed)")
        #expect(!stats.strategy.isEmpty)
    }

    @Test("Multi-turn after compression: VM remains usable")
    func multiTurn_afterCompression_vmRemainsUsable() async throws {
        try createAndActivateSession()
        await fillContext()

        // First post-compression message
        mock.tokensToYield = ["First", " post"]
        vm.inputText = "Post compression 1"
        await vm.sendMessage()
        #expect(vm.lastCompressionStats != nil)

        // Second message — VM should still work
        mock.tokensToYield = ["Second", " post"]
        vm.inputText = "Post compression 2"
        await vm.sendMessage()

        let assistants = vm.messages.filter { $0.role == .assistant }
        #expect(assistants.count >= 2, "Should have at least 2 assistant replies after compression")
        #expect(!vm.isGenerating)
    }

    @Test("Compressed messages survive session reload")
    func compressedMessages_surviveSessionReload() async throws {
        let session = try createAndActivateSession()
        await fillContext()

        mock.tokensToYield = ["Persisted"]
        vm.inputText = "Persist after compress"
        await vm.sendMessage()

        let messageCountBefore = vm.messages.count

        // Reload session
        vm.switchToSession(session)

        #expect(vm.messages.count == messageCountBefore, "Messages should round-trip through SwiftData")
    }

    @Test("Below threshold: compression does not fire")
    func belowThreshold_noCompression() async throws {
        try createAndActivateSession()

        // Default contextMaxTokens=2048, single short message won't trigger
        mock.tokensToYield = ["Short", " reply"]
        vm.inputText = "Hello"
        await vm.sendMessage()

        #expect(vm.lastCompressionStats == nil, "Compression should not fire for a single short message")
        #expect(vm.messages.count == 2)
    }
}

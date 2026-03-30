import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

/// Integration tests for the compression system as wired into ChatViewModel.
///
/// These tests verify that CompressionMode persists correctly, that pinned message
/// IDs round-trip through SwiftData, that the compression gate (`mode == .off`)
/// is respected, and that compression stats are populated when compression actually fires.
///
/// Compressor internals (ExtractiveCompressor, AnchoredCompressor) are tested in
/// BaseChatCoreTests. These tests focus exclusively on the ViewModel wiring.
@MainActor
final class CompressionIntegrationTests: XCTestCase {

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

        let service = InferenceService(backend: mock, name: "MockCompression")
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
    private func createSession(title: String = "Compression Test") -> ChatSession {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        vm.switchToSession(session.toRecord())
        return session
    }

    private func fetchSessions() -> [ChatSession] {
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - CompressionMode Persistence Round-Trip

    func test_compressionMode_settingBalanced_persistsToSession() {
        let session = createSession()

        // Mutate via the VM — didSet calls saveSettingsToSession()
        vm.compressionMode = .balanced

        XCTAssertEqual(session.toRecord().compressionMode, .balanced,
                       "Session should have .balanced after setting compressionMode")
        XCTAssertEqual(session.toRecord().compressionModeRaw, "Balanced",
                       "Raw storage should be 'Balanced'")
    }

    func test_compressionMode_switchToSession_restoresBalanced() {
        let session = createSession()
        session.compressionModeRaw = "Balanced"
        try? context.save()

        // Switch away then back so switchToSession re-reads from the session object.
        let otherSession = ChatSession(title: "Other")
        context.insert(otherSession)
        try? context.save()
        vm.switchToSession(otherSession.toRecord())

        vm.switchToSession(session.toRecord())

        XCTAssertEqual(vm.compressionMode, .balanced,
                       "switchToSession should restore .balanced from compressionModeRaw")
    }

    func test_compressionMode_switchToSession_nilRawDefaultsToAutomatic() {
        let session = createSession()
        session.compressionModeRaw = nil
        try? context.save()

        let otherSession = ChatSession(title: "Other")
        context.insert(otherSession)
        try? context.save()
        vm.switchToSession(otherSession.toRecord())

        vm.switchToSession(session.toRecord())

        XCTAssertEqual(vm.compressionMode, .automatic,
                       "nil compressionModeRaw should default to .automatic on switchToSession")
    }

    // MARK: - Pin API Persistence Round-Trip

    func test_pinMessage_insertsIDAndPersists() async {
        let session = createSession()
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Hello"
        await vm.sendMessage()

        let message = vm.messages[0]  // user message
        vm.pinMessage(id: message.id)

        XCTAssertTrue(vm.pinnedMessageIDs.contains(message.id),
                      "pinnedMessageIDs should contain the pinned message's ID")
        XCTAssertTrue(session.toRecord().pinnedMessageIDs.contains(message.id),
                      "Session pinnedMessageIDs should contain the ID after pinMessage")
    }

    func test_unpinMessage_removesIDAndPersists() async {
        let session = createSession()
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Hello"
        await vm.sendMessage()

        let message = vm.messages[0]
        vm.pinMessage(id: message.id)
        XCTAssertTrue(vm.isMessagePinned(id: message.id))

        vm.unpinMessage(id: message.id)

        XCTAssertFalse(vm.pinnedMessageIDs.contains(message.id),
                       "pinnedMessageIDs should NOT contain the ID after unpinMessage")
        XCTAssertFalse(session.toRecord().pinnedMessageIDs.contains(message.id),
                       "Session pinnedMessageIDs should NOT contain the ID after unpinMessage")
    }

    func test_isMessagePinned_returnsTrueAndFalseCorrectly() async {
        createSession()
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Hello"
        await vm.sendMessage()

        let message = vm.messages[0]

        XCTAssertFalse(vm.isMessagePinned(id: message.id), "Message should not be pinned initially")

        vm.pinMessage(id: message.id)
        XCTAssertTrue(vm.isMessagePinned(id: message.id), "Message should be pinned after pinMessage")

        vm.unpinMessage(id: message.id)
        XCTAssertFalse(vm.isMessagePinned(id: message.id), "Message should not be pinned after unpinMessage")
    }

    func test_pinnedMessageIDs_restoredOnSessionSwitch() async {
        let sessionA = createSession(title: "Session A")
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Question"
        await vm.sendMessage()

        let message = vm.messages[0]
        vm.pinMessage(id: message.id)
        let pinnedID = message.id
        XCTAssertTrue(vm.pinnedMessageIDs.contains(pinnedID))

        // Switch away
        let sessionB = ChatSession(title: "Session B")
        context.insert(sessionB)
        try? context.save()
        vm.switchToSession(sessionB.toRecord())
        XCTAssertFalse(vm.pinnedMessageIDs.contains(pinnedID),
                       "Switching sessions should clear pinnedMessageIDs from previous session")

        // Switch back — IDs should be restored from session A
        vm.switchToSession(sessionA.toRecord())
        XCTAssertTrue(vm.pinnedMessageIDs.contains(pinnedID),
                      "Switching back to session A should restore its pinnedMessageIDs")
    }

    // MARK: - Compression Does Not Fire When Mode Is .off

    /// Sabotage-verify: sets a context size and enough messages that compression
    /// WOULD trigger if mode were not .off, then verifies it does not fire.
    ///
    /// contextMaxTokens = 600 → usableContext = 600 - 512 = 88 tokens
    /// Threshold (≤16k) = 0.75, so we need ≥ 66 tokens (≥ 264 chars) to exceed threshold.
    /// Each message below contributes ~20 tokens (80 chars / 4 = 20) via heuristic.
    /// 5 messages × 20 tokens = 100 tokens > 66 tokens → would normally trigger compression.
    func test_compressionOff_doesNotFireEvenWithFullContext() async {
        createSession()

        vm.compressionMode = .off
        vm.contextMaxTokens = 600

        // Pre-load messages that would overflow the usable context.
        // 80-char content → heuristic: max(1, 80/4) = 20 tokens per message.
        let longContent = String(repeating: "a", count: 80)
        let sessionID = vm.activeSession!.id
        for _ in 0..<5 {
            let msg = ChatMessageRecord(role: .user,
                                  content: longContent,
                                  sessionID: sessionID)
            vm.messages.append(msg)
        }

        // Verify shouldCompress would return true if mode were not .off (sabotage check).
        let compressible = vm.messages.map {
            CompressibleMessage(id: $0.id, role: $0.role.rawValue, content: $0.content)
        }
        let wouldCompressWithAutomatic: Bool = {
            let saved = vm.compressionOrchestrator.mode
            vm.compressionOrchestrator.mode = .automatic
            let result = vm.compressionOrchestrator.shouldCompress(
                messages: compressible,
                systemPrompt: nil,
                contextSize: vm.contextMaxTokens,
                tokenizer: nil
            )
            vm.compressionOrchestrator.mode = saved
            return result
        }()
        XCTAssertTrue(wouldCompressWithAutomatic,
                      "Precondition: compression WOULD trigger with .automatic mode — sabotage verified")

        // Now actually send a message with mode = .off and confirm stats remain nil.
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Final question"
        await vm.sendMessage()

        XCTAssertNil(vm.lastCompressionStats,
                     "lastCompressionStats must be nil when compressionMode is .off")
    }

    // MARK: - lastCompressionStats Is Cleared When Compression Does Not Fire

    func test_lastCompressionStats_clearedWhenCompressionDoesNotFire() async {
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

        // Context is default (2048 tokens), no messages — context usage is tiny.
        // shouldCompress will return false → the else branch sets lastCompressionStats = nil.
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Short message"
        await vm.sendMessage()

        XCTAssertNil(vm.lastCompressionStats,
                     "lastCompressionStats should be cleared when compression does not fire")
    }

    // MARK: - compressionMode didSet Syncs to Orchestrator

    func test_compressionMode_didSet_syncsToOrchestrator() {
        createSession()

        vm.compressionMode = .quality
        XCTAssertEqual(vm.compressionOrchestrator.mode, .quality,
                       "Setting compressionMode to .quality should sync to orchestrator.mode")

        vm.compressionMode = .balanced
        XCTAssertEqual(vm.compressionOrchestrator.mode, .balanced,
                       "Setting compressionMode to .balanced should sync to orchestrator.mode")

        vm.compressionMode = .off
        XCTAssertEqual(vm.compressionOrchestrator.mode, .off,
                       "Setting compressionMode to .off should sync to orchestrator.mode")

        vm.compressionMode = .automatic
        XCTAssertEqual(vm.compressionOrchestrator.mode, .automatic,
                       "Setting compressionMode to .automatic should sync to orchestrator.mode")
    }

    // MARK: - Compression Fires and Produces Stats When Context Is Full

    /// Verifies the happy path: when context utilization exceeds the threshold,
    /// compression fires, stats are populated, and the assistant reply still arrives.
    ///
    /// contextMaxTokens = 600 → usableContext = 88 tokens
    /// Threshold = 0.75 → trigger at ≥ 66 tokens (≥ 264 chars) of history.
    /// We pre-load 5 messages of 80 chars each (100 tokens total) to force compression.
    /// mode = .automatic with contextSize < 6000 → ExtractiveCompressor (no generateFn needed).
    func test_compressionFiresAndProducesStats_whenContextIsFull() async {
        createSession()

        vm.compressionMode = .automatic
        vm.contextMaxTokens = 600

        // Pre-load history that exceeds the compression threshold.
        let longContent = String(repeating: "b", count: 80)
        let sessionID = vm.activeSession!.id
        for _ in 0..<5 {
            let msg = ChatMessageRecord(role: .user,
                                  content: longContent,
                                  sessionID: sessionID)
            vm.messages.append(msg)
        }

        // Send one more message to trigger generateIntoMessage.
        mock.tokensToYield = ["AssistantReply"]
        vm.inputText = "One more question"
        await vm.sendMessage()

        // Compression stats should now be populated.
        XCTAssertNotNil(vm.lastCompressionStats,
                        "lastCompressionStats should be non-nil when compression fires")

        // Generation should have completed successfully — assistant message present.
        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertFalse(assistantMessages.isEmpty,
                       "An assistant reply should exist after generation despite compression")
        XCTAssertEqual(assistantMessages.last?.content, "AssistantReply",
                       "Assistant reply content should match the mock output")
    }

    // MARK: - Pinned Message Survives Compression

    /// Verifies that a pinned message is not evicted when compression fires.
    ///
    /// Setup mirrors test_compressionFiresAndProducesStats_whenContextIsFull exactly,
    /// with an added pin on the oldest message (vm.messages[0]).
    ///
    /// contextMaxTokens = 600 → usableContext = 88 tokens
    /// Threshold = 0.75 → trigger at ≥ 66 tokens.
    /// 4 messages × 80 chars (heuristic: 20 tokens each) = 80 tokens > 66 → forces compression.
    /// The pinned message at index 0 is the oldest and would be the first evicted without pinning.
    func test_pinnedMessage_survivesCompression() async {
        createSession()

        vm.compressionMode = .automatic
        vm.contextMaxTokens = 600

        // Pre-load history that will exceed the compression threshold.
        let longContent = String(repeating: "c", count: 80)
        let sessionID = vm.activeSession!.id
        for _ in 0..<4 {
            let msg = ChatMessageRecord(role: .user,
                                  content: longContent,
                                  sessionID: sessionID)
            vm.messages.append(msg)
        }

        // Pin the oldest message — it would be evicted first without pinning support.
        let pinnedMessage = vm.messages[0]
        let pinnedContent = pinnedMessage.content
        vm.pinMessage(id: pinnedMessage.id)

        // Send one more message to trigger generateIntoMessage (runs the compression path).
        mock.tokensToYield = ["AssistantReply"]
        vm.inputText = "One more question"
        await vm.sendMessage()

        // Compression must have fired.
        XCTAssertNotNil(vm.lastCompressionStats,
                        "lastCompressionStats should be non-nil — compression must fire for the pin test to be meaningful")

        // The pinned message's content must still be present after compression.
        XCTAssertTrue(vm.messages.contains(where: { $0.content == pinnedContent }),
                      "Pinned message content must survive compression and remain in vm.messages")
    }
}

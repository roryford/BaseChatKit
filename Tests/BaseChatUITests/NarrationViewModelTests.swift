import XCTest
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

@MainActor
final class NarrationViewModelTests: XCTestCase {

    private var sut: NarrationViewModel!
    private var mockProvider: MockNarrationProvider!

    override func setUp() async throws {
        mockProvider = MockNarrationProvider()
        sut = NarrationViewModel()
        sut.configure(provider: mockProvider)
    }

    override func tearDown() async throws {
        sut = nil
        mockProvider = nil
    }

    // MARK: - Initial State

    func test_initialState_isIdle() {
        XCTAssertEqual(sut.state, .idle)
        XCTAssertEqual(sut.rate, 0.5)
        XCTAssertNil(sut.selectedVoiceID)
    }

    // MARK: - Speak

    func test_speakMessage_assistantMessage_callsProvider() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello world", sessionID: UUID())
        await sut.speakMessage(message)

        XCTAssertEqual(mockProvider.speakCallCount, 1)
        XCTAssertEqual(mockProvider.lastSpokenText, "Hello world")
        XCTAssertEqual(mockProvider.lastMessageID, message.id)
        XCTAssertEqual(mockProvider.lastRate, 0.5)
    }

    func test_speakMessage_userMessage_doesNotCallProvider() async {
        let message = ChatMessageRecord(role: .user, content: "Hello world", sessionID: UUID())
        await sut.speakMessage(message)

        XCTAssertEqual(mockProvider.speakCallCount, 0)
    }

    func test_speakMessage_emptyContent_doesNotCallProvider() async {
        let message = ChatMessageRecord(role: .assistant, content: "", sessionID: UUID())
        await sut.speakMessage(message)

        XCTAssertEqual(mockProvider.speakCallCount, 0)
    }

    func test_speakMessage_systemMessage_doesNotCallProvider() async {
        let message = ChatMessageRecord(role: .system, content: "System prompt", sessionID: UUID())
        await sut.speakMessage(message)

        XCTAssertEqual(mockProvider.speakCallCount, 0)
    }

    func test_speakMessage_stripsMarkdown() async {
        let message = ChatMessageRecord(role: .assistant, content: "**Bold** and *italic*", sessionID: UUID())
        await sut.speakMessage(message)

        XCTAssertEqual(mockProvider.lastSpokenText, "Bold and italic")
    }

    func test_speakMessage_usesSelectedVoice() async {
        sut.selectedVoiceID = "mock-voice-2"
        let message = ChatMessageRecord(role: .assistant, content: "Test", sessionID: UUID())
        await sut.speakMessage(message)

        XCTAssertEqual(mockProvider.lastVoice, "mock-voice-2")
    }

    func test_speakMessage_usesCustomRate() async {
        sut.rate = 0.8
        let message = ChatMessageRecord(role: .assistant, content: "Test", sessionID: UUID())
        await sut.speakMessage(message)

        XCTAssertEqual(mockProvider.lastRate, 0.8)
    }

    // MARK: - State Transitions

    func test_speakMessage_transitionsToSpeaking() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello", sessionID: UUID())
        await sut.speakMessage(message)
        sut.syncState()

        XCTAssertEqual(sut.state, .speaking(messageID: message.id))
    }

    func test_toggleForMessage_whileSpeakingSameMessage_pauses() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello", sessionID: UUID())
        await sut.speakMessage(message)
        sut.syncState()

        // Toggle should pause
        await sut.toggleForMessage(message)
        sut.syncState()

        XCTAssertEqual(sut.state, .paused(messageID: message.id))
        XCTAssertEqual(mockProvider.pauseCallCount, 1)
    }

    func test_toggleForMessage_whilePaused_resumes() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello", sessionID: UUID())
        await sut.speakMessage(message)
        sut.syncState()
        await sut.toggleForMessage(message) // pause
        sut.syncState()

        // Toggle again should resume
        await sut.toggleForMessage(message)
        sut.syncState()

        XCTAssertEqual(sut.state, .speaking(messageID: message.id))
        XCTAssertEqual(mockProvider.resumeCallCount, 1)
    }

    func test_toggleForMessage_differentMessage_stopsThenSpeaksNew() async {
        let message1 = ChatMessageRecord(role: .assistant, content: "First", sessionID: UUID())
        let message2 = ChatMessageRecord(role: .assistant, content: "Second", sessionID: UUID())

        await sut.speakMessage(message1)
        sut.syncState()

        // Toggle a different message — should stop and speak new
        await sut.toggleForMessage(message2)
        sut.syncState()

        XCTAssertEqual(mockProvider.stopCallCount, 1)
        XCTAssertEqual(mockProvider.lastSpokenText, "Second")
        XCTAssertEqual(sut.state, .speaking(messageID: message2.id))
    }

    // MARK: - Stop

    func test_stopAll_resetsToIdle() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello", sessionID: UUID())
        await sut.speakMessage(message)
        sut.syncState()

        sut.stopAll()

        XCTAssertEqual(sut.state, .idle)
        XCTAssertEqual(mockProvider.stopCallCount, 1)
    }

    // MARK: - Pause / Resume

    func test_pause_whileSpeaking_pauses() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello", sessionID: UUID())
        await sut.speakMessage(message)
        sut.syncState()

        sut.pause()

        XCTAssertEqual(mockProvider.pauseCallCount, 1)
    }

    func test_resume_whilePaused_resumes() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello", sessionID: UUID())
        await sut.speakMessage(message)
        sut.syncState()
        sut.pause()

        sut.resume()

        XCTAssertEqual(mockProvider.resumeCallCount, 1)
    }

    // MARK: - Query Helpers

    func test_isNarrating_returnsTrueForActiveMessage() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello", sessionID: UUID())
        await sut.speakMessage(message)
        sut.syncState()

        XCTAssertTrue(sut.isNarrating(message.id))
        XCTAssertFalse(sut.isNarrating(UUID()))
    }

    func test_isSpeaking_distinguishesSpeakingFromPaused() async {
        let message = ChatMessageRecord(role: .assistant, content: "Hello", sessionID: UUID())
        await sut.speakMessage(message)
        sut.syncState()

        XCTAssertTrue(sut.isSpeaking(message.id))

        sut.pause()
        sut.syncState()

        XCTAssertFalse(sut.isSpeaking(message.id))
        XCTAssertTrue(sut.isNarrating(message.id))
    }

    // MARK: - Available Voices

    func test_availableVoices_delegatesToProvider() {
        XCTAssertEqual(sut.availableVoices.count, 2)
        XCTAssertEqual(sut.availableVoices.first?.id, "mock-voice-1")
    }

    func test_availableVoices_withoutProvider_returnsEmpty() {
        let vm = NarrationViewModel()
        XCTAssertTrue(vm.availableVoices.isEmpty)
    }
}

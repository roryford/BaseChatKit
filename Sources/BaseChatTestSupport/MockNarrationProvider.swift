import Foundation
import BaseChatCore

/// Configurable mock narration provider for testing.
///
/// Tracks calls and allows state manipulation without requiring audio hardware.
/// Intended for use in `@MainActor` test contexts.
public final class MockNarrationProvider: NarrationProvider, @unchecked Sendable {

    // Using nonisolated(unsafe) is acceptable here because tests run on @MainActor.
    nonisolated(unsafe) public var _state: NarrationState = .idle

    public var state: NarrationState { _state }

    // MARK: - Call Tracking

    nonisolated(unsafe) public var speakCallCount = 0
    nonisolated(unsafe) public var pauseCallCount = 0
    nonisolated(unsafe) public var resumeCallCount = 0
    nonisolated(unsafe) public var stopCallCount = 0

    nonisolated(unsafe) public var lastSpokenText: String?
    nonisolated(unsafe) public var lastMessageID: UUID?
    nonisolated(unsafe) public var lastVoice: String?
    nonisolated(unsafe) public var lastRate: Float?

    // MARK: - Configurable Behavior

    public var voicesToReturn: [NarrationVoice] = [
        NarrationVoice(id: "mock-voice-1", name: "Mock Voice", languageCode: "en-US", quality: .default),
        NarrationVoice(id: "mock-voice-2", name: "Mock Enhanced", languageCode: "en-US", quality: .enhanced),
    ]

    public init() {}

    // MARK: - NarrationProvider

    public func speak(_ text: String, messageID: UUID, voice: String?, rate: Float) async {
        speakCallCount += 1
        lastSpokenText = text
        lastMessageID = messageID
        lastVoice = voice
        lastRate = rate
        _state = .speaking(messageID: messageID)
    }

    public func pause() {
        pauseCallCount += 1
        if case .speaking(let id) = _state {
            _state = .paused(messageID: id)
        }
    }

    public func resume() {
        resumeCallCount += 1
        if case .paused(let id) = _state {
            _state = .speaking(messageID: id)
        }
    }

    public func stop() {
        stopCallCount += 1
        _state = .idle
    }

    public var availableVoices: [NarrationVoice] {
        voicesToReturn
    }

    // MARK: - Test Helpers

    /// Resets all call counts and state.
    public func reset() {
        _state = .idle
        speakCallCount = 0
        pauseCallCount = 0
        resumeCallCount = 0
        stopCallCount = 0
        lastSpokenText = nil
        lastMessageID = nil
        lastVoice = nil
        lastRate = nil
    }
}

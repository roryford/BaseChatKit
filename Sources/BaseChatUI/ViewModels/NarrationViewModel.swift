import Foundation
import Observation
import BaseChatCore

/// Manages text-to-speech narration state for the chat interface.
///
/// Views observe this via `@Environment` to show playback controls.
/// The underlying `NarrationProvider` is injected at configuration time,
/// allowing apps to substitute their own TTS engine.
@Observable
@MainActor
public final class NarrationViewModel {

    // MARK: - State

    /// The current narration state, mirrored from the provider.
    public private(set) var state: NarrationState = .idle

    /// The selected voice identifier, or `nil` for the system default.
    public var selectedVoiceID: String?

    /// Speech rate (0.0–1.0). Defaults to 0.5 (normal pace).
    public var rate: Float = 0.5

    /// All voices available from the configured provider.
    public var availableVoices: [NarrationVoice] {
        provider?.availableVoices ?? []
    }

    // MARK: - Init

    public init() {}

    // MARK: - Provider

    private var provider: NarrationProvider?

    /// Configures the view model with a narration provider.
    public func configure(provider: NarrationProvider) {
        self.provider = provider
    }

    // MARK: - Actions

    /// Speaks the content of an assistant message, stripping markdown first.
    public func speakMessage(_ message: ChatMessageRecord) async {
        guard message.role == .assistant, !message.content.isEmpty else { return }

        let plainText = MarkdownStripper.strip(message.content)
        await provider?.speak(plainText, messageID: message.id, voice: selectedVoiceID, rate: rate)
        syncState()
    }

    /// Toggles narration for a message: starts if idle/different, stops if same.
    public func toggleForMessage(_ message: ChatMessageRecord) async {
        if state.messageID == message.id {
            switch state {
            case .speaking:
                provider?.pause()
                syncState()
            case .paused:
                provider?.resume()
                syncState()
            case .idle:
                await speakMessage(message)
            }
        } else {
            provider?.stop()
            await speakMessage(message)
        }
    }

    /// Pauses narration if currently speaking.
    public func pause() {
        provider?.pause()
        syncState()
    }

    /// Resumes narration if currently paused.
    public func resume() {
        provider?.resume()
        syncState()
    }

    /// Stops all narration.
    public func stopAll() {
        provider?.stop()
        syncState()
    }

    /// Whether the given message is currently being narrated.
    public func isNarrating(_ messageID: UUID) -> Bool {
        state.messageID == messageID
    }

    /// Whether narration is currently speaking (not paused).
    public func isSpeaking(_ messageID: UUID) -> Bool {
        if case .speaking(let id) = state, id == messageID {
            return true
        }
        return false
    }

    // MARK: - Internal

    /// Syncs observable state from the provider. Called after any provider action.
    func syncState() {
        state = provider?.state ?? .idle
    }
}

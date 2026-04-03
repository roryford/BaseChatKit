import Foundation

/// The current state of text-to-speech narration.
public enum NarrationState: Sendable, Equatable {
    /// No narration is active.
    case idle
    /// Currently speaking the content of the specified message.
    case speaking(messageID: UUID)
    /// Narration is paused for the specified message.
    case paused(messageID: UUID)

    /// The message ID being narrated, if any.
    public var messageID: UUID? {
        switch self {
        case .idle: return nil
        case .speaking(let id), .paused(let id): return id
        }
    }
}

/// Describes an available TTS voice.
public struct NarrationVoice: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let languageCode: String
    public let quality: Quality

    public enum Quality: Sendable, Hashable {
        case `default`
        case enhanced
        case premium
    }

    public init(id: String, name: String, languageCode: String, quality: Quality) {
        self.id = id
        self.name = name
        self.languageCode = languageCode
        self.quality = quality
    }
}

/// Provides text-to-speech narration for chat messages.
///
/// Protocol lives in `BaseChatCore` so apps can substitute their own TTS engine
/// (e.g., ElevenLabs, a custom on-device model). The default `AVSpeechSynthesizer`
/// implementation lives in `BaseChatUI`.
public protocol NarrationProvider: AnyObject, Sendable {
    /// The current narration state.
    var state: NarrationState { get }

    /// Speaks the given text, associating it with the specified message.
    func speak(_ text: String, messageID: UUID, voice: String?, rate: Float) async

    /// Pauses narration if currently speaking.
    func pause()

    /// Resumes narration if currently paused.
    func resume()

    /// Stops narration and resets to idle.
    func stop()

    /// All voices available from this provider.
    var availableVoices: [NarrationVoice] { get }
}

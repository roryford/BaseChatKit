import AVFoundation
import BaseChatCore

/// Default `NarrationProvider` implementation using Apple's `AVSpeechSynthesizer`.
///
/// Uses on-device speech synthesis with no network requirement. Supports voice
/// selection, rate control, and pause/resume. Delegate callbacks update state
/// which the `NarrationViewModel` polls after each action.
public final class AVSpeechNarrationProvider: NSObject, NarrationProvider, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()

    private var _state: NarrationState = .idle
    public var state: NarrationState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - NarrationProvider

    public func speak(_ text: String, messageID: UUID, voice: String?, rate: Float) async {
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        // rate is 0.0–1.0 from the VM; map linearly to the AVSpeechUtterance range.
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate
            + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * rate

        if let voiceID = voice {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
        }

        setState(.speaking(messageID: messageID))
        synthesizer.speak(utterance)
    }

    public func pause() {
        if case .speaking(let id) = state {
            synthesizer.pauseSpeaking(at: .word)
            setState(.paused(messageID: id))
        }
    }

    public func resume() {
        if case .paused(let id) = state {
            synthesizer.continueSpeaking()
            setState(.speaking(messageID: id))
        }
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        setState(.idle)
    }

    public var availableVoices: [NarrationVoice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            NarrationVoice(
                id: voice.identifier,
                name: voice.name,
                languageCode: voice.language,
                quality: .default
            )
        }
    }

    // MARK: - Private

    private func setState(_ newState: NarrationState) {
        lock.lock()
        _state = newState
        lock.unlock()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AVSpeechNarrationProvider: AVSpeechSynthesizerDelegate {

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        setState(.idle)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        setState(.idle)
    }
}

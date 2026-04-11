/// Events emitted by inference backends during text generation.
///
/// Replaces the raw `String` token stream to support usage reporting and
/// future structured output without breaking the `InferenceBackend`
/// contract again.
public enum GenerationEvent: Sendable, Equatable {
    /// A fragment of generated text (typically one token).
    case token(String)

    /// Token usage reported by the backend (cloud backends only today).
    case usage(prompt: Int, completion: Int)
}

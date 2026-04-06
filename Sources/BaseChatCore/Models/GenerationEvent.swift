/// Events emitted by inference backends during text generation.
///
/// Replaces the raw `String` token stream to support tool calling (#55),
/// usage reporting, and future structured output without breaking the
/// `InferenceBackend` contract again.
public enum GenerationEvent: Sendable {
    /// A fragment of generated text (typically one token).
    case token(String)

    /// A tool/function call emitted by the model.
    case toolCall(name: String, arguments: String)

    /// Token usage reported by the backend (cloud backends only today).
    case usage(prompt: Int, completion: Int)

    /// The generation stream has finished normally.
    case done
}

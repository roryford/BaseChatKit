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

    /// A tool invocation requested by the model.
    ///
    /// Backends that support tool calling (``BackendCapabilities/supportsToolCalling``)
    /// emit this event when the model decides to call a tool defined in
    /// ``GenerationConfig/tools``.  The host is responsible for executing the
    /// call and feeding a ``ToolResult`` back into the conversation.
    case toolCall(ToolCall)
}

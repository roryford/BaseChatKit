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

    /// A fragment of model reasoning (inside a thinking block). Streamed during generation.
    case thinkingToken(String)

    /// Reasoning block complete (depth 1→0 transition). Finalize accumulated thinking content.
    case thinkingComplete

    /// The orchestrator terminated a tool-dispatch loop because the per-request
    /// iteration budget (``GenerationConfig/maxToolIterations``) was reached.
    ///
    /// Emitted exactly once per turn when the loop stops for this reason. The
    /// associated value is the iteration count that ran before termination, so
    /// UI surfaces can differentiate a budget hit from an organic stop.
    case toolLoopLimitReached(iterations: Int)

    /// Result of a tool dispatched by the orchestrator in response to a
    /// ``toolCall(_:)`` event.
    ///
    /// Emitted after the coordinator has routed a ``ToolCall`` through the
    /// registered ``ToolRegistry`` and produced a ``ToolResult``. Downstream
    /// consumers (chat UIs, transcripts) use this to append the tool result to
    /// the assistant turn before the next generation round begins.
    case toolResult(ToolResult)

    /// Emitted at the start of a turn when the backend reused a KV-cache prefix
    /// from the previous turn. `promptTokensReused` is the number of prompt tokens
    /// whose KV state was preserved, saving their re-decode cost.
    case kvCacheReuse(promptTokensReused: Int)
}

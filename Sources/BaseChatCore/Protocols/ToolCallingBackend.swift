import Foundation

/// Maximum number of tool call rounds per generation to prevent runaway loops.
///
/// Each round may contain one or more tool calls. After this limit, the backend
/// should stop calling tools and return whatever text the model has generated.
public let maximumToolCallRounds = 10

/// Opt-in protocol for backends that support tool/function calling.
///
/// Backends that adopt this protocol can accept tool definitions and execute
/// tool calls during generation. The tool-calling loop runs inside the backend:
/// `generate()` still returns `AsyncThrowingStream<String, Error>` so consumers
/// see only text tokens, while tool calls happen transparently.
///
/// For backends that want to surface tool call activity to the UI, the
/// `toolCallObserver` property allows an observer to receive notifications.
public protocol ToolCallingBackend: InferenceBackend {
    /// Sets the tools available for the next generation call.
    ///
    /// Pass an empty array to disable tool calling for the next request.
    /// Called by `InferenceService` before `generate()` when a `ToolProvider`
    /// is configured.
    func setTools(_ tools: [ToolDefinition])

    /// Sets the tool provider for executing tool calls during generation.
    ///
    /// The backend calls `execute(_:)` on this provider when the model
    /// requests a tool call, feeding the result back to the model.
    func setToolProvider(_ provider: (any ToolProvider)?)

    /// Optional observer for tool call activity.
    var toolCallObserver: (any ToolCallObserver)? { get set }
}


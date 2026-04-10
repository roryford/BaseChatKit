import Foundation

/// Policy that controls whether tool calls run automatically or require
/// explicit user approval before execution.
///
/// The approval gate lives on ``InferenceService/toolApprovalCoordinator``.
/// BaseChatKit defaults to ``alwaysAsk`` because tool calling can invoke
/// destructive side effects (file deletion, HTTP requests, outbound email)
/// that must never run silently in a framework whose host app cannot predict
/// which tools a model will request. Apps that know their tools are safe —
/// for example a read-only web search — can opt into ``autoApprove`` or
/// ``trustedTools(_:)`` at setup time.
public enum ToolCallApprovalMode: Sendable, Equatable {

    /// Every tool call is paused until the user decides what to do.
    case alwaysAsk

    /// Tool calls whose name matches one of the listed names auto-approve;
    /// all others are paused for user decision.
    ///
    /// This is the right mode for apps that ship a mix of safe read-only
    /// tools and risky write tools from the same provider — e.g. auto-allow
    /// `get_weather` but gate `send_email`.
    case trustedTools(Set<String>)

    /// All tool calls run immediately, matching pre-approval behaviour.
    ///
    /// Only select this mode when you control every tool the model can see
    /// and have audited them for safe, reversible side effects.
    case autoApprove

    /// Returns `true` when a tool of the given name runs without prompting.
    public func allowsAutoApproval(of toolName: String) -> Bool {
        switch self {
        case .alwaysAsk:
            return false
        case .trustedTools(let names):
            return names.contains(toolName)
        case .autoApprove:
            return true
        }
    }
}

/// The decision a user (or approval policy) makes for a pending tool call.
public enum ToolCallApprovalDecision: Sendable, Equatable {

    /// Execute the tool with the original or edited arguments.
    ///
    /// - Parameter arguments: The JSON arguments to pass to the tool. Pass
    ///   the original arguments to approve unchanged, or an edited JSON
    ///   string to run with user-modified inputs.
    case approved(arguments: String)

    /// Skip execution and feed a synthetic rejection message back to the
    /// model as if the tool returned it.
    ///
    /// - Parameter reason: Human-readable reason shown to both the user and
    ///   the model. When `nil`, a generic message is used.
    case rejected(reason: String?)
}

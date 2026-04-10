import Foundation

/// Wraps a host-provided ``ToolProvider`` with an approval gate.
///
/// ``InferenceService`` installs this wrapper transparently when a tool
/// provider is configured so backends can call `execute(_:)` without knowing
/// whether the gate exists. The wrapper forwards the tool list through
/// unchanged but routes every execution through
/// ``ToolCallApprovalCoordinator/requestDecision(for:definition:)``.
///
/// When the decision is `.rejected`, the wrapper synthesises an error-style
/// ``ToolResult`` containing the rejection reason instead of calling the
/// underlying provider. This lets the model see the rejection and continue
/// without a dangling tool-call round.
///
/// The wrapper is marked `@unchecked Sendable` because `ToolProvider` only
/// requires `Sendable` conformance; the underlying provider is responsible
/// for its own state synchronisation. The coordinator is `@MainActor`, so
/// the approval hop crosses actors once per call.
public final class ApprovingToolProvider: ToolProvider, @unchecked Sendable {

    public let underlying: any ToolProvider
    private let coordinator: ToolCallApprovalCoordinator

    public var tools: [ToolDefinition] {
        underlying.tools
    }

    public init(underlying: any ToolProvider, coordinator: ToolCallApprovalCoordinator) {
        self.underlying = underlying
        self.coordinator = coordinator
    }

    public func execute(_ toolCall: ToolCall) async throws -> ToolResult {
        // Look up the tool definition on the underlying provider so the
        // approval sheet can show a schema-aware editor. Tools with an
        // unknown name (backend bug or streaming race) still surface to
        // the user via the sheet; the UI falls back to a raw JSON editor.
        let definition = underlying.tools.first { $0.name == toolCall.name }

        let decision = await coordinator.requestDecision(for: toolCall, definition: definition)

        switch decision {
        case .approved(let arguments):
            let effective: ToolCall
            if arguments == toolCall.arguments {
                effective = toolCall
            } else {
                effective = ToolCall(id: toolCall.id, name: toolCall.name, arguments: arguments)
            }
            return try await underlying.execute(effective)

        case .rejected(let reason):
            // Synthetic rejection result matches the tool's call ID so the
            // backend can hand it back to the model as the tool's answer.
            // `isError: true` gives the model a strong hint to try another
            // approach or ask the user for clarification.
            let message = reason ?? "User rejected this tool call."
            return ToolResult(
                toolCallID: toolCall.id,
                content: message,
                isError: true
            )
        }
    }
}

import Foundation
import Observation

/// Coordinates user approval of model-requested tool calls.
///
/// The coordinator is the single gate that tool execution paths traverse
/// before a backend runs a tool. It is owned by ``InferenceService`` and
/// wired into the execution pipeline by wrapping the host app's
/// ``ToolProvider`` in an ``ApprovingToolProvider``.
///
/// ## Flow
///
/// 1. A backend asks its (wrapped) provider to execute a ``ToolCall``.
/// 2. The wrapper calls ``requestDecision(for:)`` on this coordinator.
/// 3. If the active ``mode`` auto-approves the call, the call runs immediately.
/// 4. Otherwise the coordinator appends the call to ``pendingApprovals`` and
///    suspends on a `CheckedContinuation` until the UI invokes
///    ``resolve(id:with:)``.
///
/// The coordinator is `@MainActor` isolated so the UI can observe
/// ``pendingApprovals`` directly and mutate the active mode in response to
/// user preferences.
@Observable
@MainActor
public final class ToolCallApprovalCoordinator {

    /// A pending tool call that is waiting for user input.
    public struct PendingApproval: Identifiable, Sendable, Equatable {

        public let id: String
        public let call: ToolCall
        public let requestedAt: Date

        /// The tool definition that backs this call, when known. The sheet
        /// uses the schema to drive the edit UI; `nil` means the UI falls
        /// back to a raw JSON editor.
        public let definition: ToolDefinition?

        public init(id: String, call: ToolCall, definition: ToolDefinition?, requestedAt: Date = Date()) {
            self.id = id
            self.call = call
            self.definition = definition
            self.requestedAt = requestedAt
        }
    }

    // MARK: - Observable state

    /// The active approval policy. Mutating this does not retroactively
    /// resolve calls already waiting in ``pendingApprovals``; it only
    /// affects calls that arrive after the change.
    public var mode: ToolCallApprovalMode

    /// Tool calls currently waiting on user input, in arrival order.
    public private(set) var pendingApprovals: [PendingApproval] = []

    // MARK: - Internal state

    /// Continuations suspended on ``requestDecision(for:)``.
    ///
    /// Keyed by the pending approval ID (which matches the tool call ID).
    /// Stored outside observable state because `CheckedContinuation` is not
    /// `Equatable` and we don't want to drive view updates from it.
    private var continuations: [String: CheckedContinuation<ToolCallApprovalDecision, Never>] = [:]

    /// Records the most recent decision per pending ID so repeat
    /// ``resolve(id:with:)`` calls (e.g. from double-taps) are ignored.
    private var resolvedIDs: Set<String> = []

    public init(mode: ToolCallApprovalMode = .alwaysAsk) {
        self.mode = mode
    }

    // MARK: - API

    /// Requests a decision for the given tool call.
    ///
    /// - Parameters:
    ///   - call: The call the model wants to run.
    ///   - definition: Optional tool definition used by the edit sheet to
    ///     show a schema-aware argument editor.
    /// - Returns: The user (or policy) decision. When the active mode
    ///   auto-approves, returns `.approved(arguments:)` with the original
    ///   arguments without going through the UI at all.
    public func requestDecision(
        for call: ToolCall,
        definition: ToolDefinition? = nil
    ) async -> ToolCallApprovalDecision {
        if mode.allowsAutoApproval(of: call.name) {
            return .approved(arguments: call.arguments)
        }

        let pending = PendingApproval(id: call.id, call: call, definition: definition)
        pendingApprovals.append(pending)

        return await withCheckedContinuation { continuation in
            // If a decision has already been filed synchronously (e.g. a
            // test injected it before calling `requestDecision`), short-
            // circuit without storing the continuation.
            if resolvedIDs.contains(pending.id) {
                resolvedIDs.remove(pending.id)
                pendingApprovals.removeAll { $0.id == pending.id }
                continuation.resume(returning: .rejected(reason: "Already resolved"))
                return
            }
            continuations[pending.id] = continuation
        }
    }

    /// Resolves a pending approval with the given decision.
    ///
    /// Called by the UI when the user taps Approve, Reject, or submits an
    /// edited-arguments sheet. Safe to call multiple times — only the first
    /// resolution fires; subsequent calls are dropped.
    public func resolve(id: String, with decision: ToolCallApprovalDecision) {
        guard let continuation = continuations.removeValue(forKey: id) else {
            // Either unknown or already resolved. Record so a late
            // `requestDecision` can see it.
            resolvedIDs.insert(id)
            return
        }
        pendingApprovals.removeAll { $0.id == id }
        continuation.resume(returning: decision)
    }

    /// Rejects every pending approval with a single reason, typically when
    /// the user cancels the entire generation.
    public func rejectAllPending(reason: String? = "User cancelled") {
        let toRelease = continuations
        continuations.removeAll()
        pendingApprovals.removeAll()
        for (_, continuation) in toRelease {
            continuation.resume(returning: .rejected(reason: reason))
        }
    }
}

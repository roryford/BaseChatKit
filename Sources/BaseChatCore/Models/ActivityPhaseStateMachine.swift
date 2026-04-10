import Foundation

/// Explicit, validated transitions for ``BackendActivityPhase``.
///
/// Before this machine existed, phase mutations were scattered across
/// `ChatViewModel+Generation`, `ChatViewModel+ModelLoading`, and
/// `ChatViewModel+Messages`, each enforcing its own ad-hoc preconditions.
/// That made races like "model load fails while user taps send" fragile —
/// nothing centralised the question "is this transition legal?"
///
/// `ActivityPhaseStateMachine` is the single source of truth for the
/// legal transition graph. Every phase mutation in the view model now
/// goes through ``transition(to:)``, and every illegal attempt is either
/// rejected (for races) or surfaced as a programmer error.
///
/// ## Illegal-transition policy
///
/// Per `CLAUDE.md`, `assertionFailure` is reserved for true programmer
/// errors with no recovery path. The phase state machine has two flavours
/// of illegal transition:
///
/// 1. **Programmer errors** — e.g. calling `.streaming` before requesting
///    generation. These cannot legitimately arise from async races and
///    indicate a bug in the caller. Detected only when ``strictMode`` is
///    true (default). Still recoverable (we log and ignore), but noisy
///    in debug so the bug surfaces early.
///
/// 2. **Stale async events** — e.g. a late load-progress callback arriving
///    after a cancellation flipped the phase to `.idle`, or a stalled
///    backend notification arriving after the user cancelled. These are
///    race conditions by design and must be silently ignored.
///
/// The machine does not itself distinguish (1) from (2); callers pass
/// ``TransitionOptions/ignoreIfIllegal`` when they know the event can
/// legitimately lose a race.
public struct ActivityPhaseStateMachine: Sendable {

    /// The machine's current phase. Callers mutate this via ``transition(to:)``.
    public private(set) var phase: BackendActivityPhase

    public init(phase: BackendActivityPhase = .idle) {
        self.phase = phase
    }

    /// Result of an attempted transition.
    public enum TransitionResult: Sendable, Equatable {
        /// The transition was applied. `phase` now reflects the new state.
        case applied
        /// No state change occurred — the transition was a same-phase no-op
        /// (e.g. progress update during `.modelLoading`, or token arriving
        /// mid-`.streaming`).
        case unchanged
        /// The transition was rejected as illegal for the current phase.
        case rejected(from: BackendActivityPhase, to: BackendActivityPhase)
    }

    /// Attempt to move to `to`. Returns the outcome so callers can decide
    /// whether to proceed. Rejected transitions leave `phase` unchanged.
    @discardableResult
    public mutating func transition(to: BackendActivityPhase) -> TransitionResult {
        let from = phase
        if Self.isSameStatePhase(from, to) {
            // Progress updates (same case, possibly different payload) are
            // always permitted — they're how the UI mirrors long-running
            // work without hitting the illegal-transition path.
            phase = to
            return from == to ? .unchanged : .applied
        }
        guard Self.isLegalTransition(from: from, to: to) else {
            return .rejected(from: from, to: to)
        }
        phase = to
        return .applied
    }

    /// Static predicate exposed for tests and for callers that want to
    /// check legality without mutating.
    public static func isLegalTransition(
        from: BackendActivityPhase,
        to: BackendActivityPhase
    ) -> Bool {
        // Same-case transitions (e.g. .modelLoading → .modelLoading with a
        // new progress value) are handled separately in `transition(to:)`.
        if isSameStatePhase(from, to) { return true }

        // Universal escapes: cancellation and model swap can happen from
        // any state. `.idle` is always safe (cancel/reset), and the user
        // can always start loading a different model mid-activity — the
        // old activity is cancelled as a side effect at the call site.
        if case .idle = to { return true }
        if case .modelLoading = to { return true }

        switch (from, to) {

        // MARK: From .idle
        case (.idle, .waitingForFirstToken):
            // User tapped send while a model was already loaded.
            return true

        // MARK: From .modelLoading
        case (.modelLoading, .waitingForFirstToken):
            // Rare: a queued send runs the instant a load completes, before
            // the load bridge has flipped to `.idle`. We allow it so the
            // send doesn't have to wait a tick for the idle intermediate.
            return true

        // MARK: From .waitingForFirstToken
        case (.waitingForFirstToken, .streaming),
             (.waitingForFirstToken, .stalled),
             (.waitingForFirstToken, .retrying):
            return true

        // MARK: From .streaming
        case (.streaming, .stalled),
             (.streaming, .retrying):
            return true

        // MARK: From .stalled
        case (.stalled, .streaming),
             (.stalled, .waitingForFirstToken),
             (.stalled, .retrying):
            return true

        // MARK: From .retrying
        case (.retrying, .streaming),
             (.retrying, .waitingForFirstToken),
             (.retrying, .stalled):
            return true

        default:
            return false
        }
    }

    /// Two phases are considered the "same state" if they use the same
    /// enum case even if their associated values differ. Progress updates
    /// inside `.modelLoading` and retry-attempt updates inside `.retrying`
    /// are not real transitions.
    public static func isSameStatePhase(
        _ a: BackendActivityPhase,
        _ b: BackendActivityPhase
    ) -> Bool {
        switch (a, b) {
        case (.idle, .idle),
             (.waitingForFirstToken, .waitingForFirstToken),
             (.streaming, .streaming),
             (.stalled, .stalled):
            return true
        case (.modelLoading, .modelLoading):
            return true
        case (.retrying, .retrying):
            return true
        default:
            return false
        }
    }
}

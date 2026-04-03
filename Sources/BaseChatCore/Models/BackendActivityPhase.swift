/// Represents the current phase of backend activity, enabling UI to show appropriate indicators.
public enum BackendActivityPhase: Sendable, Equatable {
    case idle
    case modelLoading(progress: Double?)
    case waitingForFirstToken
    case streaming
}

import Foundation

/// A non-fatal error from a background housekeeping task.
///
/// Unlike `ChatError`, which represents a failure that halts a foreground
/// user action, an `OperationalError` describes a silent-but-observable
/// problem: a benchmark result that could not be cached, a stray imported
/// file that could not be cleaned up, an auto-rename that failed. These
/// errors never block the user, but the host app can surface them through
/// `DiagnosticsService` so failures are not invisible.
public enum OperationalError: Error, Sendable, Equatable {
    /// Could not delete a model file or directory left behind after a
    /// failed import or a user-initiated deletion.
    case modelFileDeletionFailed(URL, reason: String)

    /// Could not read or write the `ModelBenchmarkCache` SwiftData store.
    /// Benchmark results will not persist across launches until resolved.
    case benchmarkCacheUnavailable(reason: String)

    /// The AI-generated session title could not be produced (inference
    /// failure, empty response, or persistence write failure).
    case titleGenerationFailed(sessionID: UUID, reason: String)

    /// A concise human-readable description suitable for showing in a
    /// diagnostics disclosure or a settings warning row.
    public var localizedDescription: String {
        switch self {
        case .modelFileDeletionFailed(let url, let reason):
            return "Could not remove leftover model file at \(url.lastPathComponent): \(reason)"
        case .benchmarkCacheUnavailable(let reason):
            return "Benchmark results could not be saved: \(reason)"
        case .titleGenerationFailed(_, let reason):
            return "Automatic session rename failed: \(reason)"
        }
    }

    /// Short category label for grouping in UI.
    public var category: String {
        switch self {
        case .modelFileDeletionFailed: return "Model Storage"
        case .benchmarkCacheUnavailable: return "Benchmark Cache"
        case .titleGenerationFailed: return "Session Rename"
        }
    }
}

/// A stable-identity wrapper around an `OperationalError` for SwiftUI lists.
///
/// The warning captures the error, a timestamp, and a stable UUID so the
/// UI can animate insertions and dismissals correctly even when multiple
/// warnings share the same underlying case.
public struct OperationalWarning: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let error: OperationalError
    public let timestamp: Date

    public init(id: UUID = UUID(), error: OperationalError, timestamp: Date = Date()) {
        self.id = id
        self.error = error
        self.timestamp = timestamp
    }
}

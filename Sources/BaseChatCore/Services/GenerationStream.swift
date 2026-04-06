import Foundation
import Observation

/// Wraps an async stream of generation events with observable lifecycle state.
///
/// Consumers iterate ``events`` for content (tokens, tool calls, usage).
/// The UI observes ``phase`` for lifecycle indicators (connecting, streaming,
/// stalled, retrying, done, failed) without polling or adding lifecycle
/// cases to ``GenerationEvent``.
///
/// When ``idleTimeout`` is set, iterating ``events`` will throw
/// ``CloudBackendError/timeout(_:)`` if no event arrives within the timeout.
/// The phase transitions to `.stalled` before the timeout fires.
///
/// Thread-safe: ``setPhase(_:)`` can be called from any thread.
@Observable
public final class GenerationStream: @unchecked Sendable {

    /// The content event stream. Iterate this to receive tokens.
    ///
    /// When ``idleTimeout`` is configured, this stream monitors inter-event
    /// gaps and throws ``CloudBackendError/timeout(_:)`` if the gap exceeds
    /// the timeout. The ``phase`` transitions to `.stalled` at the midpoint
    /// of the timeout to give the UI a chance to show a warning before the
    /// hard timeout fires.
    public let events: AsyncThrowingStream<GenerationEvent, Error>

    /// Current lifecycle phase. Observed by the UI via `@Observable`.
    public private(set) var phase: Phase = .connecting

    /// Optional idle timeout. When set, ``events`` will throw
    /// ``CloudBackendError/timeout(_:)`` if no event arrives within this duration.
    public let idleTimeout: Duration?

    // MARK: - Phase

    /// Lifecycle phases for a generation stream.
    public enum Phase: Sendable, Equatable {
        /// HTTP request in flight, waiting for first byte.
        case connecting
        /// Backend is loading/pulling a model (e.g. Ollama cold start).
        case loading
        /// Tokens are actively arriving.
        case streaming
        /// No event received for longer than expected.
        case stalled
        /// Connection failed; retrying after backoff.
        case retrying(attempt: Int, of: Int)
        /// Stream completed normally.
        case done
        /// Stream terminated with an error.
        case failed(String)
    }

    // MARK: - Init

    /// Creates a generation stream wrapping the given event source.
    ///
    /// - Parameters:
    ///   - stream: The underlying async throwing stream of generation events.
    ///   - idleTimeout: Optional idle timeout duration. `nil` disables idle detection.
    public init(
        _ stream: AsyncThrowingStream<GenerationEvent, Error>,
        idleTimeout: Duration? = nil
    ) {
        self.idleTimeout = idleTimeout

        if let idleTimeout {
            // Wrap with idle timeout detection.
            self.events = Self.withIdleTimeout(
                base: stream,
                timeout: idleTimeout,
                onStalled: { [weak self] in self?.setPhase(.stalled) }
            )
        } else {
            self.events = stream
        }
    }

    // MARK: - Phase Mutation

    private let stateLock = NSLock()

    /// Updates the lifecycle phase from any thread.
    public func setPhase(_ newPhase: Phase) {
        stateLock.lock()
        defer { stateLock.unlock() }
        phase = newPhase
    }

    // MARK: - Idle Timeout

    /// Wraps a base stream with idle timeout detection.
    ///
    /// Races `Task.sleep` against the base stream's `next()`. If no event
    /// arrives within `timeout`, calls `onStalled` and throws `.timeout`.
    private static func withIdleTimeout(
        base: AsyncThrowingStream<GenerationEvent, Error>,
        timeout: Duration,
        onStalled: @escaping @Sendable () -> Void
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var iterator = base.makeAsyncIterator()

                while !Task.isCancelled {
                    do {
                        let event = try await withTimeout(timeout) {
                            try await iterator.next()
                        }

                        guard let event else {
                            // Base stream finished normally.
                            continuation.finish()
                            return
                        }

                        continuation.yield(event)
                    } catch is TimeoutError {
                        onStalled()
                        continuation.finish(throwing: CloudBackendError.timeout(timeout))
                        return
                    } catch {
                        if error is CancellationError || Task.isCancelled {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: error)
                        }
                        return
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Timeout Helper

/// Internal error used to signal that the timeout race was lost.
private struct TimeoutError: Error {}

/// Races an async operation against a timeout duration.
/// Throws `TimeoutError` if the timeout fires first.
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }

        // The first task to complete wins.
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

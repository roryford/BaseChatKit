import Foundation

/// Prevents repeated calls to a failing backend by tracking consecutive failures.
///
/// State machine:
/// - **closed**: Operations pass through normally. Consecutive failures are counted.
///   After ``failureThreshold`` failures, transitions to **open**.
/// - **open**: Operations fail immediately with ``CircuitBreakerOpenError``.
///   After ``resetTimeout``, transitions to **halfOpen**.
/// - **halfOpen**: One probe operation is allowed through. Success resets to
///   **closed**; failure returns to **open**.
///
/// Thread-safe via actor isolation.
public actor CircuitBreaker {

    public enum State: Sendable, Equatable {
        case closed
        case open
        case halfOpen
    }

    /// Current circuit state.
    public private(set) var state: State = .closed

    /// Number of consecutive failures before the circuit opens.
    public let failureThreshold: Int

    /// Time to wait in the open state before allowing a probe.
    public let resetTimeout: Duration

    private var consecutiveFailures: Int = 0
    private var lastFailureTime: ContinuousClock.Instant?

    public init(failureThreshold: Int = 5, resetTimeout: Duration = .seconds(60)) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
    }

    /// Executes an operation through the circuit breaker.
    ///
    /// - In **closed** state: passes through. Records success/failure.
    /// - In **open** state: checks if ``resetTimeout`` has elapsed. If so,
    ///   transitions to **halfOpen** and allows the call. Otherwise throws
    ///   ``CircuitBreakerOpenError``.
    /// - In **halfOpen** state: allows one call. Success → closed, failure → open.
    public func execute<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        switch state {
        case .closed:
            break

        case .open:
            if let lastFailure = lastFailureTime,
               ContinuousClock.now - lastFailure >= resetTimeout {
                state = .halfOpen
            } else {
                throw CircuitBreakerOpenError(
                    failureCount: consecutiveFailures,
                    resetTimeout: resetTimeout
                )
            }

        case .halfOpen:
            break
        }

        do {
            let result = try await operation()
            recordSuccess()
            return result
        } catch {
            recordFailure()
            throw error
        }
    }

    /// Resets the circuit breaker to closed state. Useful for manual recovery.
    public func reset() {
        state = .closed
        consecutiveFailures = 0
        lastFailureTime = nil
    }

    private func recordSuccess() {
        consecutiveFailures = 0
        state = .closed
    }

    private func recordFailure() {
        consecutiveFailures += 1
        lastFailureTime = ContinuousClock.now

        switch state {
        case .halfOpen:
            state = .open
        case .closed where consecutiveFailures >= failureThreshold:
            state = .open
        default:
            break
        }
    }
}

/// Thrown when the circuit breaker is in the open state and not yet ready
/// for a probe attempt.
public struct CircuitBreakerOpenError: Error, LocalizedError {
    public let failureCount: Int
    public let resetTimeout: Duration

    public var errorDescription: String? {
        let seconds = Int(resetTimeout.components.seconds)
        return "Circuit breaker open after \(failureCount) failures. Retry in \(seconds)s."
    }
}

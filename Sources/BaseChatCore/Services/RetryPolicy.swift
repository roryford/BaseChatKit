import Foundation

/// Executes an async operation with exponential backoff on retryable errors.
///
/// Retries any `CloudBackendError` where `isRetryable` is true (rate limits,
/// network errors, stream interruptions, 5xx server errors). Non-retryable
/// errors are thrown immediately. Uses the `Retry-After` header value when
/// available (rate limits only), otherwise falls back to exponential backoff
/// with jitter.
///
/// - Parameters:
///   - maxRetries: Maximum number of retry attempts (default 3).
///   - baseDelay: Initial delay in seconds before the first retry (default 1.0).
///   - maxTotalDelay: Maximum cumulative wait in seconds across all retries (default 60.0).
///   - operation: The async throwing operation to execute.
/// - Returns: The result of the operation.
/// - Throws: The last retryable error if all retries are exhausted, or any non-retryable error immediately.
public func withExponentialBackoff<T>(
    maxRetries: Int = 3,
    baseDelay: TimeInterval = 1.0,
    maxTotalDelay: TimeInterval = 60.0,
    operation: () async throws -> T
) async throws -> T {
    var totalDelayed: TimeInterval = 0

    for attempt in 0...maxRetries {
        do {
            return try await operation()
        } catch let error as CloudBackendError {
            guard error.isRetryable else { throw error }

            // Last attempt — don't retry, just throw.
            if attempt == maxRetries {
                throw error
            }

            // Calculate delay: use Retry-After if present (only for rate limits), otherwise exponential backoff with jitter.
            let exponentialDelay = baseDelay * pow(2.0, Double(attempt))
            let jitter = Double.random(in: 0...(exponentialDelay * 0.25))
            let retryAfter: TimeInterval? = if case .rateLimited(let ra) = error { ra } else { nil }
            let delay = retryAfter ?? (exponentialDelay + jitter)

            // Respect the total delay cap.
            guard totalDelayed + delay <= maxTotalDelay else {
                throw error
            }

            Log.network.info("Retryable error (attempt \(attempt + 1)/\(maxRetries), \(error)). Retrying in \(String(format: "%.1f", delay))s")

            try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            totalDelayed += delay

            if Task.isCancelled {
                throw error
            }
        }
    }

    // Unreachable, but the compiler needs it.
    fatalError("withExponentialBackoff: unreachable")
}

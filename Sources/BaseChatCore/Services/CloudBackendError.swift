import Foundation

/// Errors from cloud API backends (OpenAI-compatible and Claude).
public enum CloudBackendError: LocalizedError {
    case invalidURL(String)
    case authenticationFailed(provider: String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int, message: String)
    case networkError(underlying: Error)
    case parseError(String)
    case missingAPIKey
    /// The SSE or NDJSON stream was interrupted by a network failure.
    case streamInterrupted
    /// The backend object was deallocated while a stream was in flight.
    /// Not retryable — the backend no longer exists.
    case backendDeallocated
    /// No events received within the idle timeout duration.
    case timeout(Duration)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid server URL: \(url)"
        case .authenticationFailed(let provider):
            return "\(provider) authentication failed. Check your API key."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Try again in \(Int(seconds)) seconds."
            }
            return "Rate limited. Please wait before retrying."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .parseError(let detail):
            return "Failed to parse response: \(detail)"
        case .missingAPIKey:
            return "No API key configured. Add one in Settings."
        case .streamInterrupted:
            return "Response stream was interrupted."
        case .backendDeallocated:
            return "Backend was deallocated during generation."
        case .timeout(let duration):
            let totalMs = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
            if totalMs < 1000 {
                return "No response received for \(totalMs)ms."
            }
            return "No response received for \(duration.components.seconds)s."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .networkError, .streamInterrupted, .timeout:
            return true
        case .serverError(let statusCode, _):
            return statusCode >= 500
        case .invalidURL, .authenticationFailed, .parseError, .missingAPIKey, .backendDeallocated:
            return false
        }
    }
}

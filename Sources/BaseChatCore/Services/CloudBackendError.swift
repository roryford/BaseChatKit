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
    case streamInterrupted

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
        }
    }
}

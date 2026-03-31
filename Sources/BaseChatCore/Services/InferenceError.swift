import Foundation

/// Errors that can occur during model loading and inference.
public enum InferenceError: LocalizedError {
    case modelNotFound(path: String)
    case modelLoadFailed(underlying: Error)
    case inferenceFailure(String)
    case memoryInsufficient(required: UInt64, available: UInt64)
    case alreadyGenerating
    case generationError(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Model file not found at path: \(path)"
        case .modelLoadFailed(let underlying):
            return "Failed to load model: \(underlying.localizedDescription)"
        case .inferenceFailure(let message):
            return "Inference failed: \(message)"
        case .memoryInsufficient(let required, let available):
            let requiredMB = required / (1024 * 1024)
            let availableMB = available / (1024 * 1024)
            return "Insufficient memory: \(requiredMB) MB required, \(availableMB) MB available"
        case .alreadyGenerating:
            return "Cannot start generation while another generation is in progress"
        case .generationError(let message):
            return "Generation error: \(message)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .alreadyGenerating:
            return true
        case .modelNotFound, .modelLoadFailed, .inferenceFailure,
             .memoryInsufficient, .generationError:
            return false
        }
    }
}

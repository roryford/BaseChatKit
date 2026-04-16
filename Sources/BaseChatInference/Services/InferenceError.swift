import Foundation

/// Errors that can occur during model loading and inference.
public enum InferenceError: LocalizedError {
    case modelNotFound(path: String)
    case modelLoadFailed(underlying: Error)
    case inferenceFailure(String)
    case memoryInsufficient(required: UInt64, available: UInt64)
    case alreadyGenerating
    case generationError(String)
    /// Thrown by backends when `prompt_tokens + maxOutputTokens` exceeds the
    /// loaded model's effective context window. Surfaced up front so callers
    /// can trim history or reduce `maxOutputTokens` instead of seeing an
    /// opaque decode failure mid-stream once the KV cache runs out.
    case contextExhausted(promptTokens: Int, maxOutputTokens: Int, contextSize: Int)

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
        case .contextExhausted(let promptTokens, let maxOutputTokens, let contextSize):
            return "Prompt (\(promptTokens) tokens) plus requested output (\(maxOutputTokens) tokens) exceeds context window (\(contextSize) tokens)."
        }
    }

    /// Whether this error represents a transient condition that may succeed on retry.
    ///
    /// Currently only ``alreadyGenerating`` is retryable -- the caller can wait for the
    /// in-flight generation to finish and try again. All other cases indicate permanent
    /// failures (missing model, OOM, etc.).
    public var isRetryable: Bool {
        switch self {
        case .alreadyGenerating:
            return true
        case .modelNotFound, .modelLoadFailed, .inferenceFailure,
             .memoryInsufficient, .generationError, .contextExhausted:
            return false
        }
    }
}

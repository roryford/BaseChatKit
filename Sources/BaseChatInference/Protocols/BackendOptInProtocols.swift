import Foundation

// MARK: - Supporting Protocols for Backend Opt-In Capabilities

/// Adopted by backends that can vend a synchronous ``TokenizerProvider``.
///
/// Use this when a backend has an efficient, thread-safe tokenizer available after
/// model load. Backends whose tokenizer requires `async` access should not conform.
public protocol TokenizerVendor: AnyObject {
    var tokenizer: any TokenizerProvider { get }
}

/// Adopted by cloud backends to receive the full conversation history for multi-turn support.
/// This avoids InferenceService having a hard dependency on specific backend types.
public protocol ConversationHistoryReceiver: AnyObject {
    func setConversationHistory(_ messages: [(role: String, content: String)])
}

/// Adopted by cloud backends that track token usage per response.
public protocol TokenUsageProvider: AnyObject {
    var lastUsage: (promptTokens: Int, completionTokens: Int)? { get }
}

/// Adopted by cloud backends configured with endpoint URL + model name.
public protocol CloudBackendURLModelConfigurable: AnyObject {
    func configure(baseURL: URL, modelName: String)
}

/// Adopted by cloud backends that resolve API keys via a Keychain account.
public protocol CloudBackendKeychainConfigurable: AnyObject {
    func configure(baseURL: URL, keychainAccount: String, modelName: String)
}

/// Adopted by backends that can report granular model-load progress.
///
/// `InferenceService` installs a handler before each load and clears it
/// (`nil`) once the load has completed or failed. Handlers may be invoked
/// from any thread; the closure is `@Sendable`. Backends without granular
/// progress need not adopt this protocol — `InferenceService` will simply
/// publish `0.0` until `isModelLoaded` flips to `true`.
public protocol LoadProgressReporting: AnyObject {
    /// Installs (or clears, when `nil`) a progress callback for the next
    /// `loadModel` call. Values must be in `[0.0, 1.0]`. Implementations
    /// should retain the handler only for the duration of the active load.
    func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?)
}

/// Adopted by local backends that can count tokens exactly using their loaded vocabulary.
///
/// Non-local backends (cloud, Ollama) should not conform — they have no
/// local tokenizer. `GenerationCoordinator` gates the exact pre-flight
/// check on this protocol so the trim-and-retry path only activates for
/// backends where KV cache overflow is a real concern.
///
/// - Note: `countTokens` must only be called after the model is loaded.
///   Implementations throw ``InferenceError/modelNotLoaded`` when invoked
///   on an unloaded backend.
public protocol TokenCountingBackend: AnyObject {
    /// Returns the exact token count for `text` using the loaded model's vocabulary.
    ///
    /// - Throws: ``InferenceError/inferenceFailure(_:)`` if the model is not loaded,
    ///   or if tokenization fails (e.g., vocabulary is unavailable).
    func countTokens(_ text: String) throws -> Int
}

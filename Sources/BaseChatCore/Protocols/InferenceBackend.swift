import Foundation

/// Sampling and generation parameters shared across all inference backends.
public struct GenerationConfig: Sendable {
    public var temperature: Float
    public var topP: Float
    public var repeatPenalty: Float
    public var maxTokens: Int32

    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxTokens: Int32 = 512
    ) {
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxTokens = maxTokens
    }
}

/// Common interface for inference backends.
///
/// Each backend wraps a different inference engine (MLX, llama.cpp, etc.)
/// and exposes the same async streaming API. `InferenceService` picks the
/// right backend based on model format and delegates all work here.
public protocol InferenceBackend: AnyObject, Sendable {
    var isModelLoaded: Bool { get }
    var isGenerating: Bool { get }

    /// What this backend supports (parameters, context size, prompt templates).
    var capabilities: BackendCapabilities { get }

    /// Loads a model from the given URL.
    ///
    /// - For GGUF backends, `url` points to a single `.gguf` file.
    /// - For MLX backends, `url` points to a directory containing
    ///   `config.json` + `.safetensors` weights.
    func loadModel(from url: URL, contextSize: Int32) async throws

    /// Generates text from a prompt, streaming tokens as they are produced.
    /// Errors during generation are thrown into the stream.
    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error>

    /// Requests that the current generation stop as soon as possible.
    func stopGeneration()

    /// Unloads the model and frees all associated memory.
    func unloadModel()
}

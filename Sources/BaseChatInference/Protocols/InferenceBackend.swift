import Foundation

/// Sampling and generation parameters shared across all inference backends.
public struct GenerationConfig: Sendable, Codable {
    public var temperature: Float
    public var topP: Float
    public var repeatPenalty: Float
    @available(*, deprecated, renamed: "maxOutputTokens", message: "Use maxOutputTokens instead.")
    public var maxTokens: Int32
    public var topK: Int32?
    public var typicalP: Float?

    /// Maximum number of tokens the model should generate in a single response.
    ///
    /// Cloud backends send this as their `max_tokens` API parameter.
    /// Local backends (Foundation, MLX, llama.cpp) use it to cap the generation loop.
    /// `nil` means no explicit limit beyond the backend's own defaults.
    public var maxOutputTokens: Int?

    /// Tool definitions made available to the model for this generation request.
    ///
    /// Only honoured by backends that set ``BackendCapabilities/supportsToolCalling``
    /// to `true`.  Backends that do not support tool calling silently ignore this
    /// field.  Defaults to an empty array (no tools).
    public var tools: [ToolDefinition]

    /// Controls which tool, if any, the backend is allowed to call.
    ///
    /// Only honoured when ``tools`` is non-empty and the backend supports tool
    /// calling.  Defaults to ``ToolChoice/auto``.
    public var toolChoice: ToolChoice

    @available(*, deprecated, message: "Use init(temperature:topP:repeatPenalty:topK:typicalP:maxOutputTokens:) instead.")
    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxTokens: Int32,
        topK: Int32? = nil,
        typicalP: Float? = nil,
        maxOutputTokens: Int? = 2048,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto
    ) {
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxTokens = maxTokens
        self.topK = topK
        self.typicalP = typicalP
        self.maxOutputTokens = maxOutputTokens
        self.tools = tools
        self.toolChoice = toolChoice
    }

    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        topK: Int32? = nil,
        typicalP: Float? = nil,
        maxOutputTokens: Int? = 2048,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto
    ) {
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxTokens = 512
        self.topK = topK
        self.typicalP = typicalP
        self.maxOutputTokens = maxOutputTokens
        self.tools = tools
        self.toolChoice = toolChoice
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case temperature, topP, repeatPenalty, maxTokens, topK, typicalP, maxOutputTokens
        case tools, toolChoice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try c.decode(Float.self, forKey: .temperature)
        topP = try c.decode(Float.self, forKey: .topP)
        repeatPenalty = try c.decode(Float.self, forKey: .repeatPenalty)
        // maxTokens is deprecated; absent from payloads that never encoded it — fall back to 512.
        maxTokens = (try c.decodeIfPresent(Int32.self, forKey: .maxTokens)) ?? 512
        topK = try c.decodeIfPresent(Int32.self, forKey: .topK)
        typicalP = try c.decodeIfPresent(Float.self, forKey: .typicalP)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        // New fields added in v0.10; absent from payloads serialised before their introduction.
        tools = (try c.decodeIfPresent([ToolDefinition].self, forKey: .tools)) ?? []
        toolChoice = (try c.decodeIfPresent(ToolChoice.self, forKey: .toolChoice)) ?? .auto
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(topP, forKey: .topP)
        try c.encode(repeatPenalty, forKey: .repeatPenalty)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(topK, forKey: .topK)
        try c.encodeIfPresent(typicalP, forKey: .typicalP)
        try c.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try c.encode(tools, forKey: .tools)
        try c.encode(toolChoice, forKey: .toolChoice)
    }
}

/// Common interface for inference backends.
///
/// Each backend wraps a different inference engine (MLX, llama.cpp, etc.)
/// and exposes the same async streaming API. `InferenceService` picks the
/// right backend based on model format and delegates all work here.
///
/// Backends are unaware of the generation queue — they always see one
/// `generate()` call at a time. Queuing, priority ordering, and session
/// scoping are service-level concerns handled by `InferenceService`.
///
/// ## Thread Safety
///
/// `InferenceService` is `@MainActor`-isolated and calls backend methods
/// from that context, but `loadModel(from:plan:)` is dispatched via
/// `Task.detached` to avoid blocking the main thread during heavy I/O.
/// This means backend methods can be called from **any** thread.
///
/// The generation queue guarantees only one `generate()` call is active at
/// a time, but `stopGeneration()` and `unloadModel()` may arrive
/// concurrently from the main actor while generation runs on a detached
/// task. Conformers with mutable state **must** provide their own
/// synchronization (e.g. `NSLock`, actor isolation).
///
/// All concrete backends in `BaseChatBackends` conform as `@unchecked
/// Sendable` and use either `NSLock` (`LlamaBackend`, `SSECloudBackend`)
/// or actor isolation (`MLXModelContainer`) to protect mutable state.
/// Custom conformers should follow the same pattern.
public protocol InferenceBackend: AnyObject, Sendable {
    var isModelLoaded: Bool { get }
    var isGenerating: Bool { get }

    /// What this backend supports (parameters, context size, prompt templates).
    var capabilities: BackendCapabilities { get }

    /// Loads a model from the given URL, consuming a precomputed ``ModelLoadPlan``.
    ///
    /// - For GGUF backends, `url` points to a single `.gguf` file.
    /// - For MLX backends, `url` points to a directory containing
    ///   `config.json` + `.safetensors` weights.
    /// - For cloud backends, `url` is the configured base URL and the plan is
    ///   informational — cloud providers enforce their own limits server-side.
    ///
    /// The plan carries the authoritative effective context size and verdict.
    /// Callers must check `plan.verdict != .deny` before invoking this method;
    /// conformers may rely on that precondition.
    func loadModel(from url: URL, plan: ModelLoadPlan) async throws

    /// Generates a response from a prompt, streaming events as they are produced.
    /// Errors during generation are thrown into the stream.
    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream

    /// Requests that the current generation stop as soon as possible.
    ///
    /// ## Contract
    ///
    /// After `stopGeneration()` returns, the backend **must** satisfy all of:
    ///
    /// 1. **Cancel in-flight generation** — any running `generate()` stream is
    ///    terminated. The stream's `onTermination` handler fires.
    /// 2. **Ready for reuse** — the backend accepts a new `generate()` call
    ///    without requiring `loadModel()` or `resetConversation()` first.
    ///    There must be no corrupted sessions or stale state.
    /// 3. **`isGenerating` is `false`** — callers can check this synchronously
    ///    to confirm the stop took effect.
    ///
    /// Calling `stopGeneration()` when no generation is in progress is a no-op.
    func stopGeneration()

    /// Unloads the model and frees all associated memory.
    func unloadModel()

    /// Resets any accumulated conversation state without unloading the model.
    ///
    /// Backends that maintain multi-turn conversation history (e.g. Foundation)
    /// should clear it here. The default implementation is a no-op.
    func resetConversation()
}

extension InferenceBackend {
    public func resetConversation() {}
}

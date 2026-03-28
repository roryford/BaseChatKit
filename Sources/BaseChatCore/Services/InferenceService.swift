import Foundation
import Observation

/// A factory closure that creates a local inference backend for the given model type.
/// Return `nil` if this factory does not handle the given type.
public typealias BackendFactory = (ModelType) -> (any InferenceBackend)?

/// A factory closure that creates a cloud inference backend for the given API provider.
/// Return `nil` if this factory does not handle the given provider.
public typealias CloudBackendFactory = (APIProvider) -> (any InferenceBackend)?

/// Orchestrates inference across multiple backends.
///
/// Selects the appropriate backend based on model format and delegates all
/// loading, generation, and lifecycle management to it. Views and view models
/// interact only with this service, never with backends directly.
///
/// Backends are pluggable via `registerBackendFactory` and
/// `registerCloudBackendFactory`. This keeps BaseChatCore free of any
/// direct dependency on MLX, llama.cpp, Foundation Models, or cloud SDKs —
/// those are registered by the app or the BaseChatBackends target at startup.
@Observable
@MainActor
public final class InferenceService {

    // MARK: - Published State

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    /// The name of the active backend (e.g., "MLX", "llama.cpp"), for display.
    public private(set) var activeBackendName: String?

    /// The prompt template to apply for backends that require one (GGUF).
    public var selectedPromptTemplate: PromptTemplate = .chatML

    // MARK: - Computed

    /// Capabilities of the currently loaded backend, or `nil` if none loaded.
    public var capabilities: BackendCapabilities? {
        backend?.capabilities
    }

    // MARK: - Backend Registry

    private var backendFactories: [BackendFactory] = []
    private var cloudBackendFactories: [CloudBackendFactory] = []

    /// Registers a factory that can create a local inference backend.
    ///
    /// Factories are tried in registration order; the first non-nil result wins.
    public func registerBackendFactory(_ factory: @escaping BackendFactory) {
        backendFactories.append(factory)
    }

    /// Registers a factory that can create a cloud inference backend.
    ///
    /// Factories are tried in registration order; the first non-nil result wins.
    public func registerCloudBackendFactory(_ factory: @escaping CloudBackendFactory) {
        cloudBackendFactories.append(factory)
    }

    // MARK: - Private State

    private var backend: (any InferenceBackend)?

    // MARK: - Model Lifecycle

    /// Loads a model using the appropriate backend for its format.
    public func loadModel(
        from modelInfo: ModelInfo,
        contextSize: Int32 = 2048
    ) async throws {
        unloadModel()

        guard let newBackend = createBackend(for: modelInfo.modelType) else {
            throw InferenceError.inferenceFailure(
                "No registered backend can handle model type \(modelInfo.modelType). "
                + "Register a BackendFactory before loading models."
            )
        }
        try await newBackend.loadModel(from: modelInfo.url, contextSize: contextSize)

        backend = newBackend
        isModelLoaded = true
        activeBackendName = backendDisplayName(for: modelInfo.modelType)
        Log.inference.info("InferenceService loaded \(modelInfo.name) via \(self.activeBackendName ?? "unknown")")
    }

    /// Loads a cloud API backend from an APIEndpoint configuration.
    public func loadCloudBackend(from endpoint: APIEndpoint) async throws {
        unloadModel()

        guard let url = URL(string: endpoint.baseURL) else {
            throw CloudBackendError.invalidURL(endpoint.baseURL)
        }

        guard let newBackend = createCloudBackend(for: endpoint.provider) else {
            throw InferenceError.inferenceFailure(
                "No registered cloud backend factory can handle provider \(endpoint.provider.rawValue). "
                + "Register a CloudBackendFactory before loading cloud backends."
            )
        }

        try await newBackend.loadModel(from: url, contextSize: 0)
        backend = newBackend
        isModelLoaded = true
        activeBackendName = endpoint.provider.rawValue
        Log.inference.info("InferenceService loaded cloud backend: \(endpoint.name) (\(endpoint.provider.rawValue))")
    }

    /// Unloads the current model and frees all associated memory.
    public func unloadModel() {
        backend?.unloadModel()
        backend = nil
        isModelLoaded = false
        isGenerating = false
        activeBackendName = nil
    }

    // MARK: - Generation

    /// Generates text from a message history, streaming tokens via the active backend.
    ///
    /// For backends that require prompt templates (GGUF), messages are formatted
    /// into a single prompt string using `selectedPromptTemplate`. For MLX and
    /// Foundation, the last user message is passed directly (they handle chat
    /// formatting internally).
    public func generate(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let backend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        let config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty
        )

        isGenerating = true

        let prompt: String
        let effectiveSystemPrompt: String?

        if backend.capabilities.requiresPromptTemplate {
            // GGUF: format the entire conversation using the selected template.
            // System prompt is baked into the formatted string.
            prompt = selectedPromptTemplate.format(
                messages: messages,
                systemPrompt: systemPrompt
            )
            effectiveSystemPrompt = nil
        } else {
            // MLX / Foundation / Cloud: pass the last user message as prompt.
            // Cloud backends receive full history via their own mechanism.
            prompt = messages.last(where: { $0.role == "user" })?.content ?? ""
            effectiveSystemPrompt = systemPrompt
        }

        // For cloud backends, allow them to receive the full conversation history
        // via the ConversationHistoryReceiver protocol if they adopt it.
        if let historyReceiver = backend as? ConversationHistoryReceiver {
            historyReceiver.setConversationHistory(messages)
        }

        return try backend.generate(
            prompt: prompt,
            systemPrompt: effectiveSystemPrompt,
            config: config
        )
    }

    /// Token usage from the last cloud API generation, if available.
    ///
    /// Backends that track token usage should adopt the `TokenUsageProvider` protocol.
    public var lastTokenUsage: (promptTokens: Int, completionTokens: Int)? {
        (backend as? TokenUsageProvider)?.lastUsage
    }

    /// Requests that the current generation stop.
    public func stopGeneration() {
        backend?.stopGeneration()
    }

    /// Notifies the service that generation has finished (called by view model
    /// after consuming the stream).
    public func generationDidFinish() {
        isGenerating = false
    }

    // MARK: - Backend Selection

    private func createBackend(for modelType: ModelType) -> (any InferenceBackend)? {
        for factory in backendFactories {
            if let backend = factory(modelType) {
                return backend
            }
        }
        return nil
    }

    private func createCloudBackend(for provider: APIProvider) -> (any InferenceBackend)? {
        for factory in cloudBackendFactories {
            if let backend = factory(provider) {
                return backend
            }
        }
        return nil
    }

    private func backendDisplayName(for modelType: ModelType) -> String {
        switch modelType {
        case .mlx: "MLX"
        case .gguf: "llama.cpp"
        case .foundation: "Apple"
        }
    }

    // MARK: - Initializers

    public nonisolated init() {}

    #if DEBUG
    /// Creates an InferenceService with a pre-loaded backend. For tests only.
    public init(backend: any InferenceBackend, name: String = "Mock") {
        self.backend = backend
        self.isModelLoaded = true
        self.activeBackendName = name
    }
    #endif
}

// MARK: - Supporting Protocols for Cloud Backend Interop

/// Adopted by cloud backends to receive the full conversation history for multi-turn support.
/// This avoids InferenceService having a hard dependency on specific backend types.
public protocol ConversationHistoryReceiver: AnyObject {
    func setConversationHistory(_ messages: [(role: String, content: String)])
}

/// Adopted by cloud backends that track token usage per response.
public protocol TokenUsageProvider: AnyObject {
    var lastUsage: (promptTokens: Int, completionTokens: Int)? { get }
}

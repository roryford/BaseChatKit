import BaseChatInference

/// Registers the default set of backends with an InferenceService.
/// Call this at app startup after configuring BaseChatConfiguration.
///
/// ```swift
/// let service = InferenceService()
/// DefaultBackends.register(with: service)
/// ```
public enum DefaultBackends {

    // MARK: - Static Capability Queries

    /// The local model types supported by this build, without requiring
    /// an `InferenceService` instance.
    ///
    /// Useful for static checks before service construction (e.g., in unit tests
    /// or feature-flag evaluation at app startup).
    public static var supportedModelTypes: Set<ModelType> {
        var types: Set<ModelType> = []
        #if MLX
        types.insert(.mlx)
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            types.insert(.foundation)
        }
        #endif
        #if Llama
        types.insert(.gguf)
        #endif
        return types
    }

    /// Returns `true` if this build includes a backend for the given local model type.
    public static func canLoad(modelType: ModelType) -> Bool {
        supportedModelTypes.contains(modelType)
    }

    /// Returns `true` if this build includes a backend for the given API provider.
    ///
    /// All cloud API providers are always supported in `BaseChatBackends`.
    public static func canLoad(provider: APIProvider) -> Bool { true }

    // MARK: - Pure Routing Helpers

    /// Returns the name of the backend class that would handle this model type,
    /// or nil if no backend is registered for it. Used for testing routing logic
    /// without instantiating hardware-dependent backends.
    static func backendTypeName(for modelType: ModelType) -> String? {
        switch modelType {
        #if Llama
        case .gguf:       return "LlamaBackend"
        #endif
        #if MLX
        case .mlx:        return "MLXBackend"
        #endif
        #if canImport(FoundationModels)
        case .foundation: return "FoundationBackend"
        #endif
        default:          return nil
        }
    }

    static func backendTypeName(for provider: APIProvider) -> String? {
        switch provider {
        #if CloudSaaS
        case .claude:                     return "ClaudeBackend"
        case .openAI, .lmStudio, .custom: return "OpenAIBackend"
        case .openAIResponses:            return "OpenAIResponsesBackend"
        #endif
        #if Ollama
        case .ollama:                     return "OllamaBackend"
        #endif
        default: return nil
        }
    }

    // MARK: - Registration

    /// The default registrar fold. Order is significant only for
    /// `CloudBackends`, which calls `PinnedSessionDelegate.loadDefaultPins()`
    /// and must run before any URLSession factory. Local backends are
    /// independent.
    @MainActor
    public static let registrars: [any BackendRegistrar.Type] = [
        CloudBackends.self,
        MLXBackends.self,
        LlamaBackends.self,
        FoundationBackends.self,
    ]

    @MainActor
    public static func register(with service: InferenceService) {
        for registrar in registrars {
            registrar.register(with: service)
        }
    }
}

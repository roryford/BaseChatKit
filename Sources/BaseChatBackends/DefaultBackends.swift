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
        #endif
        #if Ollama
        case .ollama:                     return "OllamaBackend"
        #endif
        default: return nil
        }
    }

    // MARK: - Registration

    @MainActor
    public static func register(with service: InferenceService) {
        #if CloudSaaS
        PinnedSessionDelegate.loadDefaultPins()
        #endif

        service.registerBackendFactory { modelType in
            switch modelType {
            #if MLX
            case .mlx: return MLXBackend()
            #endif
            #if canImport(FoundationModels)
            case .foundation:
                if #available(iOS 26, macOS 26, *) {
                    return FoundationBackend()
                } else {
                    return nil
                }
            #endif
            #if Llama
            case .gguf: return LlamaBackend()
            #endif
            default: return nil
            }
        }

        // Declare which local model types this build can handle so the service
        // can answer capability queries without instantiating any backend.
        #if MLX
        service.declareSupport(for: .mlx)
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            service.declareSupport(for: .foundation)
        }
        #endif
        #if Llama
        service.declareSupport(for: .gguf)
        #endif

        service.registerCloudBackendFactory { provider in
            switch provider {
            #if CloudSaaS
            case .claude:                     return ClaudeBackend()
            case .openAI, .lmStudio, .custom: return OpenAIBackend()
            #endif
            #if Ollama
            // FIXME(#714): expected deprecation warning until Phase 2D moves
            // `Ollama` out of default traits — this internal registration is
            // the supported migration path consumers are pointed at.
            case .ollama:                     return OllamaBackend()
            #endif
            default: return nil
            }
        }

        // Declare every provider this build can actually serve — depends on
        // which of `Ollama` / `CloudSaaS` traits is enabled.
        for provider in APIProvider.availableInBuild {
            service.declareSupport(for: provider)
        }
    }
}

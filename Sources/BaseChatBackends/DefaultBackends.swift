import BaseChatCore

/// Registers the default set of backends with an InferenceService.
/// Call this at app startup after configuring BaseChatConfiguration.
///
/// ```swift
/// let service = InferenceService()
/// DefaultBackends.register(with: service)
/// ```
public enum DefaultBackends {

    // MARK: - Pure Routing Helpers

    /// Returns the name of the backend class that would handle this model type,
    /// or nil if no backend is registered for it. Used for testing routing logic
    /// without instantiating hardware-dependent backends.
    static func backendTypeName(for modelType: ModelType) -> String? {
        switch modelType {
        case .gguf:       return "LlamaBackend"
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
        case .claude:                              return "ClaudeBackend"
        case .openAI, .ollama, .lmStudio, .custom: return "OpenAIBackend"
        }
    }

    // MARK: - Registration

    @MainActor
    public static func register(with service: InferenceService) {
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
        service.registerCloudBackendFactory { provider in
            switch provider {
            case .claude: return ClaudeBackend()
            case .openAI, .ollama, .lmStudio, .custom: return OpenAIBackend()
            }
        }
    }
}

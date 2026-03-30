import BaseChatCore

/// Registers the default set of backends with an InferenceService.
/// Call this at app startup after configuring BaseChatConfiguration.
///
/// ```swift
/// let service = InferenceService()
/// DefaultBackends.register(with: service)
/// ```
public enum DefaultBackends {
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
            case .gguf: return LlamaBackend()
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

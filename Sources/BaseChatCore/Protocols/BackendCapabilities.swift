import Foundation

/// A generation parameter that a backend may or may not support.
public enum GenerationParameter: String, CaseIterable, Sendable, Codable {
    case temperature
    case topP
    case repeatPenalty
    case topK
    case typicalP
}

/// How the backend loads model weights into memory.
public enum MemoryStrategy: String, Sendable, Equatable, Codable {
    /// Model must be fully resident in RAM (e.g., MLX on unified memory).
    case resident
    /// Model is memory-mapped; only active pages + KV cache need RAM (e.g., llama.cpp).
    case mappable
    /// No local model memory needed (cloud APIs, OS-managed models).
    case external
}

/// How the backend responds to a cancellation request.
public enum CancellationStyle: String, Sendable, Equatable, Codable {
    /// Cancels via Swift task cancellation.
    case cooperative
    /// Requires calling `stopGeneration()` explicitly.
    case explicit
}

/// Describes what an inference backend supports.
///
/// The UI reads these to enable/disable controls (e.g., hide the top-p slider
/// for Apple Foundation Models which only expose temperature).
public struct BackendCapabilities: Sendable, Equatable, Codable {
    /// Which sampling parameters the backend accepts.
    public let supportedParameters: Set<GenerationParameter>

    /// Maximum context window in tokens.
    public let maxContextTokens: Int32

    /// Effective token limit for this backend/model.
    ///
    /// Convenience accessor over `maxContextTokens`. Use this when branching
    /// generation strategy based on context size (e.g., in `PromptAssembler`).
    public var contextWindowSize: Int { Int(maxContextTokens) }

    /// Maximum number of tokens the model can generate in a single response.
    public let maxOutputTokens: Int

    /// Whether the caller must format messages into a prompt string
    /// using a `PromptTemplate`. When `false`, the backend applies
    /// its own chat template internally (MLX, Foundation).
    public let requiresPromptTemplate: Bool

    /// Whether the backend supports a separate system prompt.
    public let supportsSystemPrompt: Bool

    /// Whether the backend streams tokens as they are generated.
    public let supportsStreaming: Bool

    /// Whether the backend supports tool/function calling.
    public let supportsToolCalling: Bool

    /// Whether the backend supports structured (JSON schema) output.
    public let supportsStructuredOutput: Bool

    /// How the backend handles generation cancellation.
    public let cancellationStyle: CancellationStyle

    /// Whether the backend can count tokens locally before sending a request.
    public let supportsTokenCounting: Bool

    /// How the backend loads model weights into memory.
    public let memoryStrategy: MemoryStrategy

    /// `true` for any backend that makes network calls (cloud APIs, Ollama, KoboldCpp, etc.).
    /// All remote backends must also reflect this in their `memoryStrategy`.
    public let isRemote: Bool

    /// Parameters the UI should present controls for.
    public var visibleParameters: [GenerationParameter] {
        GenerationParameter.allCases.filter { supportedParameters.contains($0) }
    }

    public init(
        supportedParameters: Set<GenerationParameter>,
        maxContextTokens: Int32,
        requiresPromptTemplate: Bool,
        supportsSystemPrompt: Bool
    ) {
        self.supportedParameters = supportedParameters
        self.maxContextTokens = maxContextTokens
        self.requiresPromptTemplate = requiresPromptTemplate
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsToolCalling = false
        self.supportsStructuredOutput = false
        self.cancellationStyle = .cooperative
        self.supportsTokenCounting = false
        self.memoryStrategy = .resident
        self.maxOutputTokens = 4096
        self.supportsStreaming = true
        self.isRemote = false
    }

    public init(
        supportedParameters: Set<GenerationParameter>,
        maxContextTokens: Int32,
        requiresPromptTemplate: Bool,
        supportsSystemPrompt: Bool,
        supportsToolCalling: Bool,
        supportsStructuredOutput: Bool,
        cancellationStyle: CancellationStyle,
        supportsTokenCounting: Bool,
        memoryStrategy: MemoryStrategy = .resident,
        maxOutputTokens: Int = 4096,
        supportsStreaming: Bool = true,
        isRemote: Bool = false
    ) {
        self.supportedParameters = supportedParameters
        self.maxContextTokens = maxContextTokens
        self.requiresPromptTemplate = requiresPromptTemplate
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsToolCalling = supportsToolCalling
        self.supportsStructuredOutput = supportsStructuredOutput
        self.cancellationStyle = cancellationStyle
        self.supportsTokenCounting = supportsTokenCounting
        self.memoryStrategy = memoryStrategy
        self.maxOutputTokens = maxOutputTokens
        self.supportsStreaming = supportsStreaming
        self.isRemote = isRemote
    }
}

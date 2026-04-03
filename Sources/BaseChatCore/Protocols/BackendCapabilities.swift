import Foundation

/// A generation parameter that a backend may or may not support.
public enum GenerationParameter: String, CaseIterable, Sendable {
    case temperature
    case topP
    case repeatPenalty
    case topK
    case typicalP
}

/// How the backend responds to a cancellation request.
public enum CancellationStyle: Sendable, Equatable {
    /// Cancels via Swift task cancellation.
    case cooperative
    /// Requires calling `stopGeneration()` explicitly.
    case explicit
}

/// Describes what an inference backend supports.
///
/// The UI reads these to enable/disable controls (e.g., hide the top-p slider
/// for Apple Foundation Models which only expose temperature).
public struct BackendCapabilities: Sendable {
    /// Which sampling parameters the backend accepts.
    public let supportedParameters: Set<GenerationParameter>

    /// Maximum context window in tokens.
    public let maxContextTokens: Int32

    /// Whether the caller must format messages into a prompt string
    /// using a `PromptTemplate`. When `false`, the backend applies
    /// its own chat template internally (MLX, Foundation).
    public let requiresPromptTemplate: Bool

    /// Whether the backend supports a separate system prompt.
    public let supportsSystemPrompt: Bool

    /// Whether the backend supports tool/function calling.
    public let supportsToolCalling: Bool

    /// Whether the backend supports structured (JSON schema) output.
    public let supportsStructuredOutput: Bool

    /// How the backend handles generation cancellation.
    public let cancellationStyle: CancellationStyle

    /// Whether the backend can count tokens locally before sending a request.
    public let supportsTokenCounting: Bool

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
    }

    public init(
        supportedParameters: Set<GenerationParameter>,
        maxContextTokens: Int32,
        requiresPromptTemplate: Bool,
        supportsSystemPrompt: Bool,
        supportsToolCalling: Bool,
        supportsStructuredOutput: Bool,
        cancellationStyle: CancellationStyle,
        supportsTokenCounting: Bool
    ) {
        self.supportedParameters = supportedParameters
        self.maxContextTokens = maxContextTokens
        self.requiresPromptTemplate = requiresPromptTemplate
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsToolCalling = supportsToolCalling
        self.supportsStructuredOutput = supportsStructuredOutput
        self.cancellationStyle = cancellationStyle
        self.supportsTokenCounting = supportsTokenCounting
    }
}

import Foundation

/// A capability a request requires of whichever backend serves it.
///
/// Used by ``GenerationConfig/requiredCapabilities`` and ``RouterBackend``
/// to fail fast when no wired backend can satisfy a request, and to dispatch
/// the request to a child backend that can.
///
/// New requirements should map onto an existing ``BackendCapabilities`` flag
/// rather than introducing a parallel system. The mapping lives in
/// ``BackendCapabilities/satisfies(_:)``.
public enum GenerationCapabilityRequirement: Sendable, Hashable, Codable {
    /// The backend must support tool/function calling
    /// (``BackendCapabilities/supportsToolCalling``).
    case toolCalling

    /// The backend must support structured (JSON-schema) output
    /// (``BackendCapabilities/supportsStructuredOutput``).
    case structuredOutput

    /// The backend must support a native JSON-object generation mode
    /// (``BackendCapabilities/supportsNativeJSONMode``).
    case jsonMode

    /// The backend must emit thinking events
    /// (``BackendCapabilities/supportsThinking``).
    case thinking

    /// The backend must support grammar-constrained sampling
    /// (``BackendCapabilities/supportsGrammarConstrainedSampling``).
    case grammarConstrainedSampling

    /// The backend must be capable of emitting multiple tool calls per turn
    /// (``BackendCapabilities/supportsParallelToolCalls``).
    case parallelToolCalls

    /// The backend must stream tool-call arguments
    /// (``BackendCapabilities/streamsToolCallArguments``).
    case streamingToolCalls

    /// The backend must persist KV cache state across consecutive
    /// `generate()` calls (``BackendCapabilities/supportsKVCachePersistence``).
    case kvCachePersistence

    /// The backend's effective context window must be at least `tokens` wide.
    case minContextTokens(Int)
}

extension BackendCapabilities {
    /// Whether this capability set satisfies a single requirement.
    public func satisfies(_ requirement: GenerationCapabilityRequirement) -> Bool {
        switch requirement {
        case .toolCalling:                return supportsToolCalling
        case .structuredOutput:           return supportsStructuredOutput
        case .jsonMode:                   return supportsNativeJSONMode
        case .thinking:                   return supportsThinking
        case .grammarConstrainedSampling: return supportsGrammarConstrainedSampling
        case .parallelToolCalls:          return supportsParallelToolCalls
        case .streamingToolCalls:         return streamsToolCallArguments
        case .kvCachePersistence:         return supportsKVCachePersistence
        case .minContextTokens(let n):    return contextWindowSize >= n
        }
    }

    /// Whether this capability set satisfies every requirement in the set.
    public func satisfies(_ requirements: Set<GenerationCapabilityRequirement>) -> Bool {
        requirements.allSatisfy { satisfies($0) }
    }

    /// Subset of `requirements` that this capability set fails to satisfy.
    /// Used for diagnostic error messages when routing fails.
    public func unsatisfied(
        from requirements: Set<GenerationCapabilityRequirement>
    ) -> Set<GenerationCapabilityRequirement> {
        Set(requirements.filter { !satisfies($0) })
    }
}

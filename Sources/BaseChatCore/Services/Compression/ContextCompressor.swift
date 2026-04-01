import Foundation

/// User-facing compression mode labels. No algorithm names are exposed to the UI.
public enum CompressionMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case off = "Off"
    case balanced = "Balanced"    // AnchoredCompressor
    case quality = "Best Quality" // AnchoredCompressor with richer prompt (future: SceneCompressor)

    public var id: String { rawValue }
}

/// The output of a compression pass, containing messages ready for inference and
/// statistics about what the compressor did.
public struct CompressionResult: Sendable {
    public let messages: [(role: String, content: String)]  // ready for inferenceService.generate
    public let stats: CompressionStats

    public init(messages: [(role: String, content: String)], stats: CompressionStats) {
        self.messages = messages
        self.stats = stats
    }
}

/// Diagnostic statistics produced alongside every compression result.
public struct CompressionStats: Sendable {
    public let strategy: String           // "extractive", "anchored", "anchored-fallback"
    public let originalNodeCount: Int
    public let outputMessageCount: Int
    public let estimatedTokens: Int
    public let compressionRatio: Double   // originalTokens / outputTokens; 1.0 = no compression
    public let keywordSurvivalRate: Double?  // nil in production; set by benchmark

    public init(
        strategy: String,
        originalNodeCount: Int,
        outputMessageCount: Int,
        estimatedTokens: Int,
        compressionRatio: Double,
        keywordSurvivalRate: Double?
    ) {
        self.strategy = strategy
        self.originalNodeCount = originalNodeCount
        self.outputMessageCount = outputMessageCount
        self.estimatedTokens = estimatedTokens
        self.compressionRatio = compressionRatio
        self.keywordSurvivalRate = keywordSurvivalRate
    }
}

/// A strategy for compressing context so it fits within a model's context window.
///
/// Conforming types implement a single `compress` method that takes the full message history
/// and returns a set of messages sized to the available token budget.
public protocol ContextCompressor: Sendable {
    var strategyName: String { get }
    func compress(
        messages: [CompressibleMessage],
        systemPrompt: String?,
        contextSize: Int,
        tokenizer: TokenizerProvider?
    ) async -> CompressionResult
}

// MARK: - Shared Helpers

public extension ContextCompressor {
    /// Convert compressible messages to message tuples.
    func messageTuples(from messages: [CompressibleMessage]) -> [(role: String, content: String)] {
        messages.map { (role: $0.role, content: $0.content) }
    }

    /// Estimate total tokens for a set of message tuples.
    func totalTokens(of messages: [(role: String, content: String)], tokenizer: TokenizerProvider?) -> Int {
        messages.reduce(0) { $0 + ContextWindowManager.estimateTokenCount($1.content, tokenizer: tokenizer) }
    }

    /// Calculate the token budget available for history (context minus system prompt and response buffer).
    func historyBudget(contextSize: Int, systemPrompt: String?, responseBuffer: Int = 512, tokenizer: TokenizerProvider?) -> Int {
        let systemTokens = systemPrompt.map { ContextWindowManager.estimateTokenCount($0, tokenizer: tokenizer) } ?? 0
        return max(0, contextSize - systemTokens - responseBuffer)
    }
}

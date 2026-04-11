import Foundation

/// Decides when compression is needed and which compression strategy to use.
///
/// The orchestrator checks context utilization against a threshold and then
/// routes to either `ExtractiveCompressor` (fast, local) or `AnchoredCompressor`
/// (higher quality, requires a generate function) based on the active mode and
/// available capabilities.
@MainActor
public final class CompressionOrchestrator {

    /// The user-selected compression mode. Defaults to automatic.
    public var mode: CompressionMode = .automatic

    public let extractive: ExtractiveCompressor
    public let anchored: AnchoredCompressor

    public init(
        extractive: ExtractiveCompressor = ExtractiveCompressor(),
        anchored: AnchoredCompressor = AnchoredCompressor()
    ) {
        self.extractive = extractive
        self.anchored = anchored
    }

    // MARK: - Threshold

    /// Returns the context utilization ratio at which compression should trigger.
    ///
    /// Larger context windows can afford to wait longer before compressing,
    /// so the threshold is higher for models with more than 16k tokens.
    public func compressionThreshold(for contextSize: Int) -> Double {
        contextSize > 16_000 ? 0.85 : 0.75
    }

    // MARK: - Should Compress

    /// Determines whether the current conversation history is large enough to
    /// warrant compression given the active mode and context window.
    public func shouldCompress(
        messages: [CompressibleMessage],
        systemPrompt: String?,
        contextSize: Int,
        tokenizer: TokenizerProvider?
    ) -> Bool {
        guard mode != .off else { return false }

        let responseBuffer = 512
        let tuples = extractive.messageTuples(from: messages)
        let tokens = extractive.totalTokens(of: tuples, tokenizer: tokenizer)
        let systemTokens = systemPrompt.map { ContextWindowManager.estimateTokenCount($0, tokenizer: tokenizer) } ?? 0
        let totalTokens = tokens + systemTokens
        let usableContext = contextSize - responseBuffer
        guard usableContext > 0 else { return false }

        let utilization = Double(totalTokens) / Double(usableContext)
        return utilization >= compressionThreshold(for: contextSize)
    }

    // MARK: - Compress

    /// Selects the appropriate compression strategy and compresses the message history.
    ///
    /// Strategy routing depends on the current ``mode``, the model's context size,
    /// and whether `AnchoredCompressor` has a generate function configured.
    public func compress(
        messages: [CompressibleMessage],
        systemPrompt: String?,
        contextSize: Int,
        tokenizer: TokenizerProvider?
    ) async -> CompressionResult {
        let strategy: ContextCompressor = selectStrategy(contextSize: contextSize)
        return await strategy.compress(
            messages: messages,
            systemPrompt: systemPrompt,
            contextSize: contextSize,
            tokenizer: tokenizer
        )
    }

    // MARK: - Private

    /// Picks a compressor based on the mode, context size, and anchored availability.
    private func selectStrategy(contextSize: Int) -> ContextCompressor {
        switch mode {
        case .off:
            // Should not normally be called when off, but fall back gracefully.
            return extractive

        case .automatic:
            if contextSize < 6000 {
                return extractive
            }
            return anchored.generateFn != nil ? anchored : extractive

        case .balanced:
            return anchored.generateFn != nil ? anchored : extractive
        }
    }
}

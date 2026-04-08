import Foundation

/// Zero-inference, deterministic compression strategy that scores messages by
/// recency, content length, and keyword density (capitalized-word proxy for proper nouns),
/// then greedily selects the highest-scoring messages within a token budget.
///
/// The newest messages are always kept verbatim (the "tail"), and pinned messages are
/// never evicted. Remaining messages compete for the leftover budget by score.
package final class ExtractiveCompressor: ContextCompressor, @unchecked Sendable {
    package let strategyName = "extractive"

    /// Fraction of the history budget reserved for the verbatim tail (newest messages).
    package let tailBudgetFraction: Double

    /// Weight for how recently a message appears in the conversation.
    package let recencyWeight: Double

    /// Weight for message content length (longer messages carry more narrative).
    package let lengthWeight: Double

    /// Weight for capitalized-word density (proxy for proper noun / keyword richness).
    package let keywordDensityWeight: Double

    package init(
        tailBudgetFraction: Double = 0.40,
        recencyWeight: Double = 0.5,
        lengthWeight: Double = 0.3,
        keywordDensityWeight: Double = 0.2
    ) {
        self.tailBudgetFraction = tailBudgetFraction
        self.recencyWeight = recencyWeight
        self.lengthWeight = lengthWeight
        self.keywordDensityWeight = keywordDensityWeight
    }

    // MARK: - ContextCompressor

    package nonisolated func compress(
        messages: [CompressibleMessage],
        systemPrompt: String?,
        contextSize: Int,
        tokenizer: TokenizerProvider?
    ) async -> CompressionResult {
        // Edge case: empty input
        guard !messages.isEmpty else {
            return CompressionResult(
                messages: [],
                stats: CompressionStats(
                    strategy: strategyName,
                    originalNodeCount: 0,
                    outputMessageCount: 0,
                    estimatedTokens: 0,
                    compressionRatio: 1.0,
                    keywordSurvivalRate: nil
                )
            )
        }

        let budget = historyBudget(contextSize: contextSize, systemPrompt: systemPrompt, tokenizer: tokenizer)
        let allTuples = messageTuples(from: messages)
        let originalTokens = totalTokens(of: allTuples, tokenizer: tokenizer)

        // If everything fits, return verbatim.
        if originalTokens <= budget {
            return CompressionResult(
                messages: allTuples,
                stats: CompressionStats(
                    strategy: strategyName,
                    originalNodeCount: messages.count,
                    outputMessageCount: allTuples.count,
                    estimatedTokens: originalTokens,
                    compressionRatio: 1.0,
                    keywordSurvivalRate: nil
                )
            )
        }

        // Single message: never evict all history.
        if messages.count == 1 {
            let tokens = ContextWindowManager.estimateTokenCount(messages[0].content, tokenizer: tokenizer)
            return CompressionResult(
                messages: allTuples,
                stats: CompressionStats(
                    strategy: strategyName,
                    originalNodeCount: 1,
                    outputMessageCount: 1,
                    estimatedTokens: tokens,
                    compressionRatio: 1.0,
                    keywordSurvivalRate: nil
                )
            )
        }

        // Pre-compute per-message token counts and keyword densities (indexed same as messages array).
        let messageTokens = messages.map { ContextWindowManager.estimateTokenCount($0.content, tokenizer: tokenizer) }
        let messageKeywordDensities = messages.map { keywordDensity(of: $0.content) }

        let tailBudget = Int(Double(budget) * tailBudgetFraction)
        let candidateBudget = budget - tailBudget

        // --- Step 1: Build the verbatim tail (newest messages) ---
        // Walk backwards, accumulating tokens. Always keep at least the last message.
        // Pinned messages go into the tail set regardless of budget.

        var tailIndices = Set<Int>()
        var tailTokensUsed = 0

        // Always include pinned messages first.
        for (i, message) in messages.enumerated() where message.isPinned {
            tailIndices.insert(i)
            tailTokensUsed += messageTokens[i]
        }

        // Walk from newest to oldest, adding to tail until budget exhausted.
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            if tailIndices.contains(i) { continue } // already pinned
            let cost = messageTokens[i]
            if tailIndices.isEmpty || tailTokensUsed + cost <= tailBudget {
                tailIndices.insert(i)
                tailTokensUsed += cost
                // Always keep at least the very last message.
                if i == messages.count - 1 { continue }
            }
            if tailTokensUsed >= tailBudget && tailIndices.contains(messages.count - 1) {
                break
            }
        }

        // Invariant: newest message must always be preserved, even when pinned
        // messages have already consumed the tail budget.
        let newestIndex = messages.count - 1
        if !tailIndices.contains(newestIndex) {
            tailIndices.insert(newestIndex)
            tailTokensUsed += messageTokens[newestIndex]
        }

        // --- Step 2: Score candidate messages ---
        // Candidates are messages not in the tail and not pinned.
        struct ScoredCandidate {
            let index: Int
            let score: Double
            let tokens: Int
        }

        var candidates: [ScoredCandidate] = []
        let messageCount = messages.count

        for i in 0..<messageCount {
            guard !tailIndices.contains(i) else { continue }

            let recencyScore = Double(i) / Double(messageCount - 1)
            let lengthScore = min(1.0, Double(messageTokens[i]) / 200.0)
            let density = messageKeywordDensities[i]

            let total = recencyScore * recencyWeight
                      + lengthScore * lengthWeight
                      + density * keywordDensityWeight

            candidates.append(ScoredCandidate(index: i, score: total, tokens: messageTokens[i]))
        }

        // Sort descending by score.
        candidates.sort { $0.score > $1.score }

        // --- Step 3: Greedy selection within candidate budget ---
        // Skip candidate selection entirely if pinned/tail messages already exceed budget.
        var selectedIndices = Set<Int>()
        var candidateTokensUsed = 0

        if tailTokensUsed <= budget {
            let effectiveCandidateBudget = min(candidateBudget, budget - tailTokensUsed)
            for candidate in candidates {
                if candidateTokensUsed + candidate.tokens <= effectiveCandidateBudget {
                    selectedIndices.insert(candidate.index)
                    candidateTokensUsed += candidate.tokens
                }
            }
        }

        // --- Step 4: Collect and re-sort chronologically ---
        let allSelectedIndices = tailIndices.union(selectedIndices).sorted()
        let outputMessages = allSelectedIndices.map { messages[$0] }
        let outputTuples = messageTuples(from: outputMessages)
        let outputTokens = totalTokens(of: outputTuples, tokenizer: tokenizer)

        let ratio: Double = outputTokens > 0 ? Double(originalTokens) / Double(outputTokens) : 1.0

        return CompressionResult(
            messages: outputTuples,
            stats: CompressionStats(
                strategy: strategyName,
                originalNodeCount: messages.count,
                outputMessageCount: outputTuples.count,
                estimatedTokens: outputTokens,
                compressionRatio: ratio,
                keywordSurvivalRate: nil
            )
        )
    }

    // MARK: - Private

    /// Ratio of capitalized-word tokens to total word tokens.
    /// A rough proxy for proper noun density (character names, locations, etc.).
    private func keywordDensity(of content: String) -> Double {
        let words = content.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return 0 }

        let capitalizedCount = words.filter { word in
            guard let first = word.first else { return false }
            return first.isUppercase
        }.count

        return Double(capitalizedCount) / Double(words.count)
    }
}

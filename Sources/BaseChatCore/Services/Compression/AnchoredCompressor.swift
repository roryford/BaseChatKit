import Foundation

/// Compressor that summarizes old messages via an inference call, then prepends the
/// summary to a verbatim tail of recent messages. Falls back to ``ExtractiveCompressor``
/// on any error (missing generate function, failed inference, oversized summary).
public final class AnchoredCompressor: ContextCompressor {
    public let strategyName = "anchored"

    /// Fraction of the history budget reserved for the verbatim recent tail.
    public var tailBudgetFraction: Double = 0.50

    /// Injected by the caller; performs a single-turn inference call for summarization.
    public var generateFn: (@Sendable (String) async throws -> String)?

    private let fallback = ExtractiveCompressor()

    // MARK: - Summary Prompt Template

    /// The prompt template used to summarize old messages.
    /// Callers can replace this with a domain-specific prompt.
    /// The placeholder `{old_nodes_text}` is replaced with the concatenated message content.
    public var summaryTemplate: String = """
        Read the story excerpt and fill in these fields. Be concise. Use only what is in the text.

        CHARACTERS: [names of characters present or mentioned, comma-separated]
        LOCATION: [current setting]
        PLOT THREADS: [up to 3 unresolved threads, semicolon-separated]
        LAST EVENT: [most recent significant event, one sentence]
        TONE: [emotional mood, 1-2 words]

        Story excerpt:
        {old_nodes_text}
        """

    public init() {}

    // MARK: - ContextCompressor

    public func compress(
        messages: [CompressibleMessage],
        systemPrompt: String?,
        contextSize: Int,
        tokenizer: TokenizerProvider?
    ) async -> CompressionResult {
        let budget = historyBudget(contextSize: contextSize, systemPrompt: systemPrompt, tokenizer: tokenizer)
        let allTuples = messageTuples(from: messages)
        let originalTokens = totalTokens(of: allTuples, tokenizer: tokenizer)

        // 1. If everything fits, return verbatim (no inference call needed).
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

        // 2. Build verbatim tail: walk from newest, accumulate tokens up to tailBudget.
        //    Pinned messages are always included.
        let tailBudget = Int(Double(budget) * tailBudgetFraction)
        var tailIndices = Set<Int>()
        var tailTokens = 0

        // Walk backwards for recency-biased tail.
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let nodeTokens = ContextWindowManager.estimateTokenCount(messages[i].content, tokenizer: tokenizer)
            if tailTokens + nodeTokens <= tailBudget || messages[i].isPinned {
                tailIndices.insert(i)
                tailTokens += nodeTokens
            }
            if tailTokens >= tailBudget && !messages[i].isPinned {
                // Keep scanning only to pick up pinned messages.
                continue
            }
        }

        // Ensure at least the newest message is in the tail.
        if tailIndices.isEmpty, !messages.isEmpty {
            tailIndices.insert(messages.count - 1)
        }

        let tailMessages = messages.indices.filter { tailIndices.contains($0) }.map { messages[$0] }
        let oldMessages = messages.indices.filter { !tailIndices.contains($0) }.map { messages[$0] }

        // 3. If nothing is old, return verbatim.
        if oldMessages.isEmpty {
            return CompressionResult(
                messages: messageTuples(from: tailMessages),
                stats: CompressionStats(
                    strategy: strategyName,
                    originalNodeCount: messages.count,
                    outputMessageCount: tailMessages.count,
                    estimatedTokens: tailTokens,
                    compressionRatio: Double(originalTokens) / Double(max(tailTokens, 1)),
                    keywordSurvivalRate: nil
                )
            )
        }

        // 4. If no generate function is available, fall back.
        guard let generate = generateFn else {
            var result = await fallback.compress(messages: messages, systemPrompt: systemPrompt, contextSize: contextSize, tokenizer: tokenizer)
            result = CompressionResult(
                messages: result.messages,
                stats: CompressionStats(
                    strategy: "anchored-fallback",
                    originalNodeCount: result.stats.originalNodeCount,
                    outputMessageCount: result.stats.outputMessageCount,
                    estimatedTokens: result.stats.estimatedTokens,
                    compressionRatio: result.stats.compressionRatio,
                    keywordSurvivalRate: result.stats.keywordSurvivalRate
                )
            )
            return result
        }

        // 5. Build the summary prompt and call inference.
        let oldText = oldMessages.map(\.content).joined(separator: "\n\n")
        let prompt = summaryTemplate.replacingOccurrences(of: "{old_nodes_text}", with: oldText)

        let summaryText: String
        do {
            summaryText = try await generate(prompt)
        } catch {
            var result = await fallback.compress(messages: messages, systemPrompt: systemPrompt, contextSize: contextSize, tokenizer: tokenizer)
            result = CompressionResult(
                messages: result.messages,
                stats: CompressionStats(
                    strategy: "anchored-fallback",
                    originalNodeCount: result.stats.originalNodeCount,
                    outputMessageCount: result.stats.outputMessageCount,
                    estimatedTokens: result.stats.estimatedTokens,
                    compressionRatio: result.stats.compressionRatio,
                    keywordSurvivalRate: result.stats.keywordSurvivalRate
                )
            )
            return result
        }

        // 6. Parse the structured summary.
        let parsedSummary = parseSummaryResponse(summaryText)

        // 7. Assemble: summary system message + verbatim tail.
        var outputMessages: [(role: String, content: String)] = [("system", parsedSummary)]
        outputMessages.append(contentsOf: messageTuples(from: tailMessages))

        let outputTokens = totalTokens(of: outputMessages, tokenizer: tokenizer)

        // 8. If summary + tail exceeds budget, the summary was too long -- fall back.
        if outputTokens > budget {
            var result = await fallback.compress(messages: messages, systemPrompt: systemPrompt, contextSize: contextSize, tokenizer: tokenizer)
            result = CompressionResult(
                messages: result.messages,
                stats: CompressionStats(
                    strategy: "anchored-fallback",
                    originalNodeCount: result.stats.originalNodeCount,
                    outputMessageCount: result.stats.outputMessageCount,
                    estimatedTokens: result.stats.estimatedTokens,
                    compressionRatio: result.stats.compressionRatio,
                    keywordSurvivalRate: result.stats.keywordSurvivalRate
                )
            )
            return result
        }

        // 9. Return the anchored result.
        return CompressionResult(
            messages: outputMessages,
            stats: CompressionStats(
                strategy: strategyName,
                originalNodeCount: messages.count,
                outputMessageCount: outputMessages.count,
                estimatedTokens: outputTokens,
                compressionRatio: Double(originalTokens) / Double(max(outputTokens, 1)),
                keywordSurvivalRate: nil
            )
        )
    }

    // MARK: - Summary Parsing

    /// Extracts structured fields from the summary response and reassembles them.
    /// Falls back to a trimmed raw response if fewer than 2 fields are found.
    private func parseSummaryResponse(_ response: String) -> String {
        let pattern = "^(CHARACTERS|LOCATION|PLOT THREADS|LAST EVENT|TONE):\\s*(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else {
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "[Summary unavailable]" : String(trimmed.prefix(400))
        }

        var fields: [(name: String, value: String)] = []
        let nsString = response as NSString
        let results = regex.matches(in: response, range: NSRange(location: 0, length: nsString.length))
        for match in results {
            guard match.numberOfRanges >= 3 else { continue }
            let name = nsString.substring(with: match.range(at: 1))
            let value = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                fields.append((name: name, value: value))
            }
        }

        if fields.count >= 2 {
            return fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        }

        // Fewer than 2 fields: use raw response, trimmed.
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "[Summary unavailable]"
        }
        return String(trimmed.prefix(400))
    }
}

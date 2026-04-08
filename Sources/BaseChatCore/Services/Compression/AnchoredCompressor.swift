import Foundation

/// Compressor that summarizes old messages via an inference call, then prepends the
/// summary to a verbatim tail of recent messages. Falls back to ``ExtractiveCompressor``
/// on any error (missing generate function, failed inference, oversized summary).
package final class AnchoredCompressor: ContextCompressor, @unchecked Sendable {
    package let strategyName = "anchored"

    /// Fraction of the history budget reserved for the verbatim recent tail.
    package let tailBudgetFraction: Double

    /// Injected by the caller; performs a single-turn inference call for summarization.
    /// Must be set before the first call to `compress()`. Not safe to mutate while
    /// `compress()` is in flight.
    package var generateFn: (@Sendable (String) async throws -> String)?

    private let fallback = ExtractiveCompressor()

    // MARK: - Summary Prompt Template

    package static let defaultSummaryTemplate: String = """
        Summarize the conversation so far. Be concise. Use only what is in the text.

        TOPIC: [main subject of the conversation, brief]
        KEY POINTS: [up to 3 important points, semicolon-separated]
        OPEN QUESTIONS: [unresolved items or pending decisions, if any]
        LAST DISCUSSED: [most recent topic or conclusion, one sentence]

        Conversation:
        {old_nodes_text}
        """

    /// The prompt template used to summarize old messages.
    /// Pass a domain-specific prompt at init time to override.
    /// The placeholder `{old_nodes_text}` is replaced with the concatenated message content.
    package let summaryTemplate: String

    package init(
        tailBudgetFraction: Double = 0.50,
        summaryTemplate: String? = nil
    ) {
        self.tailBudgetFraction = tailBudgetFraction
        self.summaryTemplate = summaryTemplate ?? Self.defaultSummaryTemplate
    }

    // MARK: - ContextCompressor

    package func compress(
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
            let newestIndex = messages.count - 1
            tailIndices.insert(newestIndex)
            tailTokens += ContextWindowManager.estimateTokenCount(messages[newestIndex].content, tokenizer: tokenizer)
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
            return await fallbackResult(messages: messages, systemPrompt: systemPrompt, contextSize: contextSize, tokenizer: tokenizer)
        }

        // 5. Build the summary prompt and call inference.
        let oldText = oldMessages.map(\.content).joined(separator: "\n\n")
        let prompt = summaryTemplate.replacingOccurrences(of: "{old_nodes_text}", with: oldText)

        let summaryText: String
        do {
            try Task.checkCancellation()
            summaryText = try await generate(prompt)
        } catch {
            // On cancellation, return a minimal result rather than starting a new
            // fallback compression pass that will also be cancelled.
            if error is CancellationError {
                return CompressionResult(
                    messages: messageTuples(from: tailMessages),
                    stats: CompressionStats(
                        strategy: "anchored-cancelled",
                        originalNodeCount: messages.count,
                        outputMessageCount: tailMessages.count,
                        estimatedTokens: tailTokens,
                        compressionRatio: Double(originalTokens) / Double(max(tailTokens, 1)),
                        keywordSurvivalRate: nil
                    )
                )
            }
            return await fallbackResult(messages: messages, systemPrompt: systemPrompt, contextSize: contextSize, tokenizer: tokenizer)
        }

        // 6. If the summary is empty, fall back to extractive instead of injecting a placeholder.
        guard !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return await fallbackResult(messages: messages, systemPrompt: systemPrompt, contextSize: contextSize, tokenizer: tokenizer)
        }

        // 7. Parse the structured summary.
        let parsedSummary = parseSummaryResponse(summaryText)

        // 8. Assemble: summary system message + verbatim tail.
        var outputMessages: [(role: String, content: String)] = [("system", parsedSummary)]
        outputMessages.append(contentsOf: messageTuples(from: tailMessages))

        let outputTokens = totalTokens(of: outputMessages, tokenizer: tokenizer)

        // 9. If summary + tail exceeds budget, try truncating the summary first.
        if outputTokens > budget {
            let summaryBudget = budget - tailTokens
            if summaryBudget > 0 {
                let truncated = truncateToFit(parsedSummary, budget: summaryBudget, tokenizer: tokenizer)
                guard !truncated.isEmpty else {
                    return await fallbackResult(messages: messages, systemPrompt: systemPrompt, contextSize: contextSize, tokenizer: tokenizer)
                }
                var truncatedOutput: [(role: String, content: String)] = [("system", truncated)]
                truncatedOutput.append(contentsOf: messageTuples(from: tailMessages))
                let truncatedTokens = totalTokens(of: truncatedOutput, tokenizer: tokenizer)
                if truncatedTokens <= budget {
                    return CompressionResult(
                        messages: truncatedOutput,
                        stats: CompressionStats(
                            strategy: strategyName,
                            originalNodeCount: messages.count,
                            outputMessageCount: truncatedOutput.count,
                            estimatedTokens: truncatedTokens,
                            compressionRatio: Double(originalTokens) / Double(max(truncatedTokens, 1)),
                            keywordSurvivalRate: nil
                        )
                    )
                }
            }

            return await fallbackResult(messages: messages, systemPrompt: systemPrompt, contextSize: contextSize, tokenizer: tokenizer)
        }

        // 10. Return the anchored result.
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

    // MARK: - Fallback

    private func fallbackResult(
        messages: [CompressibleMessage],
        systemPrompt: String?,
        contextSize: Int,
        tokenizer: TokenizerProvider?
    ) async -> CompressionResult {
        let result = await fallback.compress(
            messages: messages, systemPrompt: systemPrompt,
            contextSize: contextSize, tokenizer: tokenizer
        )
        return CompressionResult(
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
    }

    // MARK: - Summary Parsing

    /// Extracts structured fields from the summary response and reassembles them.
    /// Falls back to a trimmed raw response if fewer than 2 fields are found.
    /// Recognises both the domain-neutral fields (TOPIC, KEY POINTS, OPEN QUESTIONS,
    /// LAST DISCUSSED) and legacy story fields (CHARACTERS, LOCATION, etc.) so that
    /// custom templates work transparently.
    private func parseSummaryResponse(_ response: String) -> String {
        let pattern = "^([A-Z][A-Z _]*[A-Z]):\\s*(.+)$"
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

    /// Truncates text word-by-word from the end until it fits within the token budget.
    private func truncateToFit(_ text: String, budget: Int, tokenizer: TokenizerProvider?) -> String {
        if ContextWindowManager.estimateTokenCount(text, tokenizer: tokenizer) <= budget {
            return text
        }
        var words = text.split(separator: " ", omittingEmptySubsequences: true)
        while !words.isEmpty {
            words.removeLast()
            let candidate = words.joined(separator: " ")
            if ContextWindowManager.estimateTokenCount(candidate, tokenizer: tokenizer) <= budget {
                return candidate
            }
        }
        return ""
    }
}

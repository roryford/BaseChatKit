import Foundation

/// Assembles prompt slots and conversation history into a context-budgeted prompt.
///
/// The assembler follows this algorithm:
/// 1. Calculate token cost of each enabled slot's content (capped by ``PromptSlot/tokenBudget``).
/// 2. Sort slots by ``PromptSlotPosition/sortIndex(messageCount:)``.
/// 3. Sum slot tokens and subtract from the context budget (along with ``responseBuffer``).
/// 4. Allocate remaining budget to message history.
/// 5. Trim messages newest-first (same strategy as ``ContextWindowManager``).
/// 6. Insert history-positioned slots into the message stream at their resolved depth.
/// 7. Return an ``AssembledPrompt`` with ordered slots, trimmed messages, total tokens, and per-slot breakdown.
public enum PromptAssembler {

    /// Assembles slots and messages using context window size from `BackendCapabilities`.
    ///
    /// Convenience overload that reads `contextWindowSize` directly from capabilities,
    /// so callers don't need to thread the value separately.
    public static func assemble(
        slots: [PromptSlot],
        messages: [ChatMessageRecord],
        systemPrompt: String?,
        capabilities: BackendCapabilities,
        responseBuffer: Int = 512,
        tokenizer: TokenizerProvider? = nil
    ) -> AssembledPrompt {
        assemble(
            slots: slots,
            messages: messages,
            systemPrompt: systemPrompt,
            contextSize: capabilities.contextWindowSize,
            responseBuffer: responseBuffer,
            tokenizer: tokenizer
        )
    }

    /// Assembles slots and messages into a budgeted prompt.
    ///
    /// - Parameters:
    ///   - slots: Prompt slots to include. Disabled slots are skipped.
    ///   - messages: Full conversation history in chronological order.
    ///   - systemPrompt: Optional system prompt (assembled as a slot with id "system" at ``PromptSlotPosition/systemPreamble``).
    ///   - contextSize: Total context window size in tokens.
    ///   - responseBuffer: Tokens reserved for the model's response.
    ///   - tokenizer: Optional tokenizer. Falls back to ``HeuristicTokenizer`` when nil.
    /// - Returns: An ``AssembledPrompt`` containing resolved slots, trimmed messages, and budget info.
    public static func assemble(
        slots: [PromptSlot],
        messages: [ChatMessageRecord],
        systemPrompt: String?,
        contextSize: Int,
        responseBuffer: Int = 512,
        tokenizer: TokenizerProvider? = nil
    ) -> AssembledPrompt {
        let tok = tokenizer ?? HeuristicTokenizer()

        // 1. Build the system prompt slot if provided
        var allSlots = slots.filter { $0.isEnabled }
        if let systemPrompt, !systemPrompt.isEmpty {
            let systemSlot = PromptSlot(
                id: "system",
                content: systemPrompt,
                position: .systemPreamble,
                label: "System Prompt"
            )
            allSlots.insert(systemSlot, at: 0)
        }

        // 2. Resolve each slot's token cost
        var resolvedSlots: [ResolvedSlot] = []
        var budgetBreakdown: [String: Int] = [:]

        for slot in allSlots {
            let rawCount = tok.tokenCount(slot.content)
            let tokenCount = slot.tokenBudget.map { min(rawCount, $0) } ?? rawCount
            resolvedSlots.append(ResolvedSlot(
                id: slot.id, label: slot.label, content: slot.content,
                tokenCount: tokenCount, position: slot.position
            ))
            budgetBreakdown[slot.id] = tokenCount
        }

        // 3. Calculate total slot tokens and remaining budget for messages
        let totalSlotTokens = resolvedSlots.reduce(0) { $0 + $1.tokenCount }
        let availableForMessages = max(0, contextSize - totalSlotTokens - responseBuffer)

        // 4. Trim messages to fit remaining budget (newest first, like ContextWindowManager).
        // totalTokens comes free from the trim loop — no second pass needed.
        let (trimmedMessages, messageTokens) = trimMessagesToFit(messages, budget: availableForMessages, tokenizer: tok)
        budgetBreakdown["history"] = messageTokens

        // 5. Sort resolved slots by position for final ordering.
        // Tiebreak by input-array index to keep declaration order stable for equal positions.
        let mc = trimmedMessages.count
        let sortedSlots = resolvedSlots
            .enumerated()
            .sorted {
                let li = $0.element.position.sortIndex(messageCount: mc)
                let ri = $1.element.position.sortIndex(messageCount: mc)
                return li == ri ? $0.offset < $1.offset : li < ri
            }
            .map(\.element)

        // 6. Build the final message list, inserting history-positioned slots
        let finalMessages = insertSlotsIntoHistory(slots: sortedSlots, messages: trimmedMessages)

        return AssembledPrompt(
            orderedSlots: sortedSlots,
            messages: finalMessages,
            totalTokens: totalSlotTokens + messageTokens,
            budgetBreakdown: budgetBreakdown
        )
    }

    // MARK: - Private Helpers

    /// Trims messages to fit within the given token budget.
    /// Walks backward from the newest message. When `budget <= 0`, it prefers keeping
    /// the most recent user message, or falls back to the newest message if no user
    /// message exists. Returns both the trimmed messages and their total token count,
    /// so the caller does not need a second pass to compute the budget breakdown.
    private static func trimMessagesToFit(
        _ messages: [ChatMessageRecord],
        budget: Int,
        tokenizer: TokenizerProvider
    ) -> (messages: [ChatMessageRecord], totalTokens: Int) {
        guard !messages.isEmpty else { return ([], 0) }

        if budget <= 0 {
            if let lastUser = messages.last(where: { $0.role == .user }) {
                return ([lastUser], tokenizer.tokenCount(lastUser.content))
            }
            let last = messages.suffix(1)
            return (Array(last), last.reduce(0) { $0 + tokenizer.tokenCount($1.content) })
        }

        var kept: [ChatMessageRecord] = []
        var usedTokens = 0

        for message in messages.reversed() {
            let count = tokenizer.tokenCount(message.content)
            if usedTokens + count > budget && !kept.isEmpty { break }
            kept.append(message)
            usedTokens += count
        }

        return (kept.reversed(), usedTokens)
    }

    /// Inserts slots into the message history based on their position.
    ///
    /// Top slots (``PromptSlotPosition/systemPreamble`` and ``PromptSlotPosition/contextSetup``)
    /// are prepended as system messages before the history stream.
    /// History-positioned slots are inserted at `max(0, count - depth)` from the bottom,
    /// using the original message count so insertion order does not shift targets.
    private static func insertSlotsIntoHistory(
        slots: [ResolvedSlot],
        messages: [ChatMessageRecord]
    ) -> [(role: String, content: String)] {
        let topSlots = slots.filter { $0.position.isTopSlot }
        let historySlots = slots.filter { !$0.position.isTopSlot }

        var result: [(role: String, content: String)] = topSlots.map { (role: "system", content: $0.content) }
        var messageTuples = messages.map { (role: $0.role.rawValue, content: $0.content) }

        // Process lowest depth first (bottom-to-top) using the original message count
        // for all index calculations, so that earlier inserts don't perturb the targets
        // of later ones. For slots at the same depth, reverse input order before inserting
        // so that the final array reflects the original input order.
        let originalCount = messageTuples.count
        let sorted = historySlots
            .enumerated()
            .sorted { lhs, rhs in
                let ld = lhs.element.position.insertionDepth(messageCount: originalCount)
                let rd = rhs.element.position.insertionDepth(messageCount: originalCount)
                // Ascending depth (bottom first); within same depth, reverse offset so
                // final order matches input order after same-index inserts.
                return ld == rd ? lhs.offset > rhs.offset : ld < rd
            }
            .map(\.element)
        for slot in sorted {
            let depth = slot.position.insertionDepth(messageCount: originalCount)
            let idx = max(0, originalCount - depth)
            messageTuples.insert((role: "system", content: slot.content), at: idx)
        }

        result.append(contentsOf: messageTuples)
        return result
    }
}

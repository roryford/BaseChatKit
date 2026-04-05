import Foundation

/// Assembles prompt slots and conversation history into a context-budgeted prompt.
///
/// The assembler follows this algorithm:
/// 1. Calculate token cost of each enabled slot's content (capped by ``PromptSlot/tokenBudget``).
/// 2. Sort fixed slots by depth (0 = top).
/// 3. Sum fixed slot tokens and subtract from the context budget (along with ``responseBuffer``).
/// 4. Allocate remaining budget to message history.
/// 5. Trim messages newest-first (same strategy as ``ContextWindowManager/trimMessages(_:systemPrompt:maxTokens:responseBuffer:)``).
/// 6. Insert depth-positioned slots into the message stream. A slot with depth N is inserted
///    N message turns from the bottom of the history.
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
    ///   - systemPrompt: Optional system prompt (assembled as a slot with id "system" at depth 0).
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
                depth: 0,
                label: "System Prompt"
            )
            allSlots.insert(systemSlot, at: 0)
        }

        // 2. Resolve each slot's token cost
        var resolvedSlots: [ResolvedSlot] = []
        var budgetBreakdown: [String: Int] = [:]

        for slot in allSlots {
            let rawCount = tok.tokenCount(slot.content)
            let tokenCount: Int
            if let budget = slot.tokenBudget {
                tokenCount = min(rawCount, budget)
            } else {
                tokenCount = rawCount
            }
            let resolved = ResolvedSlot(
                id: slot.id,
                label: slot.label,
                content: slot.content,
                tokenCount: tokenCount,
                depth: slot.depth
            )
            resolvedSlots.append(resolved)
            budgetBreakdown[slot.id] = tokenCount
        }

        // 3. Calculate total slot tokens and remaining budget for messages
        let totalSlotTokens = resolvedSlots.reduce(0) { $0 + $1.tokenCount }
        let availableForMessages = max(0, contextSize - totalSlotTokens - responseBuffer)

        // 4. Trim messages to fit remaining budget (newest first, like ContextWindowManager)
        let trimmedMessages = trimMessagesToFit(
            messages,
            budget: availableForMessages,
            tokenizer: tok
        )

        // Calculate message tokens
        let messageTokens = trimmedMessages.reduce(0) { $0 + tok.tokenCount($1.content) }
        budgetBreakdown["history"] = messageTokens

        // 5. Sort resolved slots by depth for final ordering
        let sortedSlots = resolvedSlots.sorted { $0.depth < $1.depth }

        // 6. Build the final message list, inserting depth-positioned slots
        //    Depth N means: insert N message turns from the bottom of the history.
        //    Slots with depth 0 go before all messages.
        let finalMessages = insertSlotsIntoHistory(
            slots: sortedSlots,
            messages: trimmedMessages
        )

        let totalTokens = totalSlotTokens + messageTokens

        return AssembledPrompt(
            orderedSlots: sortedSlots,
            messages: finalMessages,
            totalTokens: totalTokens,
            budgetBreakdown: budgetBreakdown
        )
    }

    // MARK: - Private Helpers

    /// Trims messages to fit within the given token budget.
    /// Walks backward from the newest message, always keeping at least the last message.
    private static func trimMessagesToFit(
        _ messages: [ChatMessageRecord],
        budget: Int,
        tokenizer: TokenizerProvider
    ) -> [ChatMessageRecord] {
        guard !messages.isEmpty else { return [] }

        if budget <= 0 {
            // No room — keep just the last user message or the very last message
            if let lastUser = messages.last(where: { $0.role == .user }) {
                return [lastUser]
            }
            return Array(messages.suffix(1))
        }

        var kept: [ChatMessageRecord] = []
        var usedTokens = 0

        for message in messages.reversed() {
            let count = tokenizer.tokenCount(message.content)
            if usedTokens + count > budget && !kept.isEmpty {
                break
            }
            kept.append(message)
            usedTokens += count
        }

        return kept.reversed()
    }

    /// Inserts slots into the message history based on their depth.
    ///
    /// Depth 0 slots produce entries before all messages.
    /// Depth N (where N > 0) slots are inserted N turns from the bottom of the history.
    /// Slots that share a depth are kept in their sorted order.
    private static func insertSlotsIntoHistory(
        slots: [ResolvedSlot],
        messages: [ChatMessageRecord]
    ) -> [(role: String, content: String)] {
        // Separate slots into "top" (depth 0) and "depth-inserted"
        let topSlots = slots.filter { $0.depth == 0 }
        let depthSlots = slots.filter { $0.depth > 0 }

        // Convert messages to (role, content) tuples
        var result: [(role: String, content: String)] = []

        // Add top-level slots first
        for slot in topSlots {
            result.append((role: "system", content: slot.content))
        }

        // Convert ChatMessageRecords
        var messageTuples = messages.map { (role: $0.role.rawValue, content: $0.content) }

        // Insert depth-positioned slots into the message list.
        // Depth N = N turns from the bottom. Process highest depth first to
        // keep insertion indices stable.
        let sortedDepthSlots = depthSlots.sorted { $0.depth > $1.depth }
        for slot in sortedDepthSlots {
            let insertionIndex = max(0, messageTuples.count - slot.depth)
            messageTuples.insert(
                (role: "system", content: slot.content),
                at: insertionIndex
            )
        }

        result.append(contentsOf: messageTuples)
        return result
    }
}

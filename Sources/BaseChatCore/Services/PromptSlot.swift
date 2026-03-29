import Foundation

/// A named slot in the prompt assembly pipeline.
///
/// Each slot carries content that occupies part of the context window budget.
/// Slots are ordered by ``depth`` (0 = top of prompt, higher = closer to the
/// end / closer to the most recent messages). Slots with the same depth are
/// ordered by their position in the input array.
///
/// Use ``PromptAssembler/assemble(slots:messages:systemPrompt:contextSize:responseBuffer:tokenizer:)``
/// to resolve slots and history into a final ``AssembledPrompt``.
public struct PromptSlot: Identifiable, Sendable {
    /// Unique identifier for this slot (e.g. "system", "charDef", "lorebook", "authorsNote", "history").
    public let id: String

    /// The text content of this slot.
    public var content: String

    /// Ordering depth. 0 = top of prompt, higher values = closer to the end.
    /// Slots like "authorsNote" typically use a depth that places them N turns
    /// from the bottom of the conversation history.
    public var depth: Int

    /// Maximum token budget for this slot. `nil` means the slot uses as many
    /// tokens as its content requires (no cap).
    public var tokenBudget: Int?

    /// Whether this slot is active. Disabled slots are skipped during assembly.
    public var isEnabled: Bool

    /// Human-readable display name for prompt inspector UI.
    public var label: String

    public init(
        id: String,
        content: String,
        depth: Int = 0,
        tokenBudget: Int? = nil,
        isEnabled: Bool = true,
        label: String
    ) {
        self.id = id
        self.content = content
        self.depth = depth
        self.tokenBudget = tokenBudget
        self.isEnabled = isEnabled
        self.label = label
    }
}

/// A slot whose token cost has been calculated and finalized.
public struct ResolvedSlot: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let content: String
    public let tokenCount: Int
    public let depth: Int

    public init(id: String, label: String, content: String, tokenCount: Int, depth: Int) {
        self.id = id
        self.label = label
        self.content = content
        self.tokenCount = tokenCount
        self.depth = depth
    }
}

/// The output of ``PromptAssembler/assemble(slots:messages:systemPrompt:contextSize:responseBuffer:tokenizer:)``.
public struct AssembledPrompt: Sendable {
    /// All resolved slots in their final order (depth-sorted).
    public let orderedSlots: [ResolvedSlot]

    /// Trimmed conversation history as (role, content) pairs in chronological order.
    public let messages: [(role: String, content: String)]

    /// Total tokens consumed by slots + messages.
    public let totalTokens: Int

    /// Per-slot token usage keyed by slot id.
    public let budgetBreakdown: [String: Int]

    public init(
        orderedSlots: [ResolvedSlot],
        messages: [(role: String, content: String)],
        totalTokens: Int,
        budgetBreakdown: [String: Int]
    ) {
        self.orderedSlots = orderedSlots
        self.messages = messages
        self.totalTokens = totalTokens
        self.budgetBreakdown = budgetBreakdown
    }
}

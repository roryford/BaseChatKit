import Foundation

/// Describes where a ``PromptSlot`` appears in the assembled prompt.
///
/// Use semantic positions rather than raw depth integers to make slot placement
/// intent explicit and independent of the history length at assembly time.
public enum PromptSlotPosition: Hashable, Sendable {
    /// Before all other content — the very top of the prompt.
    case systemPreamble
    /// After the system preamble, before conversation history.
    case contextSetup
    /// Injected `n` messages from the bottom of the trimmed history.
    /// `n` must be >= 0; `atDepth(0)` is equivalent to ``bottomOfHistory``.
    case atDepth(Int)
    /// Just above the oldest visible message — the top of history.
    case topOfHistory
    /// Just above the most recent user message — the bottom of history.
    case bottomOfHistory
    /// Inserted after all history messages, immediately before the model turn.
    case inline
}

extension PromptSlotPosition: Codable {
    private enum CodingKeys: String, CodingKey { case type, depth }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .type)
        switch t {
        case "systemPreamble":  self = .systemPreamble
        case "contextSetup":    self = .contextSetup
        case "atDepth":
            let depth = try c.decode(Int.self, forKey: .depth)
            guard depth >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .depth, in: c,
                    debugDescription: "PromptSlotPosition.atDepth depth must be >= 0, got \(depth)"
                )
            }
            self = .atDepth(depth)
        case "topOfHistory":    self = .topOfHistory
        case "bottomOfHistory": self = .bottomOfHistory
        case "inline":          self = .inline
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown PromptSlotPosition type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemPreamble:   try c.encode("systemPreamble", forKey: .type)
        case .contextSetup:     try c.encode("contextSetup", forKey: .type)
        case .atDepth(let n):   try c.encode("atDepth", forKey: .type); try c.encode(n, forKey: .depth)
        case .topOfHistory:     try c.encode("topOfHistory", forKey: .type)
        case .bottomOfHistory:  try c.encode("bottomOfHistory", forKey: .type)
        case .inline:           try c.encode("inline", forKey: .type)
        }
    }
}

extension PromptSlotPosition {
    /// Whether this position places the slot before the message history stream.
    var isTopSlot: Bool {
        if case .systemPreamble = self { return true }
        if case .contextSetup = self { return true }
        return false
    }

    /// A stable sort key that reflects the order slots appear in the assembled prompt
    /// (top to bottom; low index = earlier in prompt).
    ///
    /// systemPreamble (0) and contextSetup (1) come first.
    /// topOfHistory (2) is the highest history position.
    /// atDepth(n): larger n means higher placement (further from latest turn), so smaller index.
    /// bottomOfHistory sits just above the last message; inline follows all messages.
    func sortIndex(messageCount: Int) -> Int {
        switch self {
        case .systemPreamble:   return 0
        case .contextSetup:     return 1
        case .topOfHistory:     return 2
        case .atDepth(let n):   return 2 + (messageCount - n)
        case .bottomOfHistory:  return 2 + messageCount
        case .inline:           return 3 + messageCount
        }
    }

    /// The number of messages from the bottom of history at which to insert the slot.
    ///
    /// Pass the original (pre-insertion) message count so that insertion order
    /// does not shift subsequent targets.
    func insertionDepth(messageCount: Int) -> Int {
        switch self {
        case .topOfHistory:             return messageCount
        case .atDepth(let n):           return n
        case .bottomOfHistory, .inline: return 0
        default:                        return 0
        }
    }

    /// Short human-readable label suitable for inspector UI.
    public var displayName: String {
        switch self {
        case .systemPreamble:   return "system preamble"
        case .contextSetup:     return "context setup"
        case .atDepth(let n):   return "depth \(n)"
        case .topOfHistory:     return "top of history"
        case .bottomOfHistory:  return "bottom of history"
        case .inline:           return "inline"
        }
    }
}

/// A named slot in the prompt assembly pipeline.
///
/// Each slot carries content that occupies part of the context window budget.
/// Slots are placed according to their ``position``; slots with the same
/// effective position retain their input-array order.
///
/// Use ``PromptAssembler/assemble(slots:messages:systemPrompt:contextSize:responseBuffer:tokenizer:)``
/// to resolve slots and history into a final ``AssembledPrompt``.
public struct PromptSlot: Identifiable, Sendable {
    /// Unique identifier for this slot (e.g. "system", "charDef", "lorebook", "authorsNote").
    public let id: String

    /// The text content of this slot.
    public var content: String

    /// Where this slot appears in the assembled prompt.
    public var position: PromptSlotPosition

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
        position: PromptSlotPosition = .contextSetup,
        tokenBudget: Int? = nil,
        isEnabled: Bool = true,
        label: String
    ) {
        if case .atDepth(let n) = position {
            precondition(n >= 0, "PromptSlotPosition.atDepth depth must be >= 0; got \(n)")
        }
        self.id = id
        self.content = content
        self.position = position
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
    public let position: PromptSlotPosition

    public init(id: String, label: String, content: String, tokenCount: Int, position: PromptSlotPosition) {
        self.id = id
        self.label = label
        self.content = content
        self.tokenCount = tokenCount
        self.position = position
    }
}

/// The output of ``PromptAssembler/assemble(slots:messages:systemPrompt:contextSize:responseBuffer:tokenizer:)``.
public struct AssembledPrompt: Sendable {
    /// All resolved slots in their final order (position-sorted).
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

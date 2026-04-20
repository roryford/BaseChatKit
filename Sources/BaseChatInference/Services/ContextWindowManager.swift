import Foundation

/// Manages context window budgeting and message trimming.
///
/// Uses a simple character-count heuristic (~4 chars per token) for estimation.
/// A real tokenizer can replace this in a future cycle.
///
/// ## Reservation policy (audit as of 2026-04-20)
///
/// Today the trim budget is computed as
/// `available = maxTokens - systemPromptTokens - responseBuffer`, where
/// `responseBuffer` is a **caller-supplied constant** (default `512`). The manager
/// itself has no knowledge of ``GenerationConfig`` — in particular it does not see
/// ``GenerationConfig/maxOutputTokens`` or ``GenerationConfig/maxThinkingTokens``
/// and therefore cannot size the reservation to the real per-request limits.
///
/// ### Per-caller reservation today
///
/// - `BaseChatUI.GenerationCoordinator` passes a hardcoded `responseBuffer: 512`
///   (see `Sources/BaseChatUI/ViewModels/GenerationCoordinator.swift`). This value
///   is independent of both `maxOutputTokens` and `maxThinkingTokens`.
/// - `BaseChatInference.PromptAssembler` uses the same hardcoded default of `512`
///   when no `responseBuffer` is supplied.
/// - `BaseChatInference.GenerationCoordinator.exactPreflightAndTrim` performs a
///   second pass with an exact tokenizer and uses `config.maxOutputTokens ?? 2048`
///   as its reservation. **It does not fold in `config.maxThinkingTokens`.** With
///   P4 semantics where thinking tokens are produced in-context before visible
///   tokens (see Ollama backend note below), this underestimates how much of the
///   context window the model will actually consume.
/// - `BaseChatBackends.OllamaBackend` reserves thinking budget at the wire layer
///   by sending `num_predict = (maxOutputTokens ?? 2048) + (maxThinkingTokens ??
///   2048)`. That keeps the server from cutting a reasoning model off mid-think,
///   but does **not** feed back into the client-side prompt-trim budget above.
/// - `BaseChatBackends.LlamaGenerationDriver` enforces `config.maxThinkingTokens`
///   as a cap on emitted reasoning tokens only; it does not influence prompt
///   trimming, which happens upstream in the coordinator.
/// - MLX and Foundation backends ignore `maxThinkingTokens` entirely.
///
/// ### Is `maxThinkingTokens` included in the reservation today?
///
/// **No, at every layer that matters for context safety.** The UI coordinator's
/// hardcoded `512` happens to cover a small chain-of-thought (≤ ~2 KB), but a
/// reasoning model emitting a long think block can push the observed context
/// usage past `maxTokens` even when `exactPreflightAndTrim` says the prompt fits.
/// That's a silent truncation / OOB-read risk rather than a crash, because
/// thinking tokens don't feed back into the prompt on subsequent turns — but
/// within a single turn they consume KV slots that the trim math doesn't reserve.
///
/// ### Required changes for P4 (`maxThinkingTokens: nil | 0 | N`)
///
/// P4 changes the public semantics of `GenerationConfig.maxThinkingTokens`:
/// `nil` = backend default, `0` = disable thinking (Ollama sends `think: false`),
/// `N` = explicit cap. With an explicit cap published by the host, the trim
/// math should reserve it so the prompt is trimmed aggressively enough to leave
/// room for the full advertised visible + thinking output.
///
/// Specific gaps to close in P4 (or a follow-up ticket):
///
/// - `BaseChatInference.GenerationCoordinator.exactPreflightAndTrim`: reserve
///   `maxOutput + (config.maxThinkingTokens ?? 0)` instead of `maxOutput` alone.
///   A `nil` value means "use the backend default" — substitute whatever the
///   backend advertises (see below) rather than treating it as zero.
/// - `BaseChatUI.GenerationCoordinator`: derive `responseBuffer` from
///   `config.maxOutputTokens + (config.maxThinkingTokens ?? 0)` (clamped to the
///   context size) instead of the hardcoded `512`. Alternatively add an overload
///   to ``ContextWindowManager/trimMessages(_:systemPrompt:maxTokens:responseBuffer:tokenizer:)``
///   that takes a `GenerationConfig` and derives the buffer internally.
/// - ``BackendCapabilities``: publish a `defaultMaxThinkingTokens` so the
///   coordinator can substitute a per-backend sane value when the host passes
///   `nil` (Ollama uses `2048` implicitly in `buildRequest`; mirror that here).
/// - `BaseChatBackends.OllamaBackend.buildRequest`: when `maxThinkingTokens == 0`,
///   send `think: false` on the wire and drop the thinking component from
///   `num_predict` (this is the P4 core change).
///
/// None of the above is a ship-blocker for P4 — the current math over-reserves
/// for most requests via the hardcoded `512`, so the observable symptom is
/// "reasoning models lose a few turns of history sooner than they needed to"
/// rather than a crash. But once the host publishes explicit thinking caps, the
/// trim math should honour them for correctness and to prevent silent truncation
/// on long-reasoning prompts. Follow-up tracked as issue #587.
public enum ContextWindowManager {

    /// Estimates the token count of a string.
    ///
    /// When a ``TokenizerProvider`` is supplied, it is used for an accurate count.
    /// Otherwise falls back to the ~4 chars-per-token heuristic.
    public static func estimateTokenCount(_ text: String, tokenizer: TokenizerProvider? = nil) -> Int {
        if let tokenizer {
            return tokenizer.tokenCount(text)
        }
        return HeuristicTokenizer().tokenCount(text)
    }

    /// Resolves the effective context size from available sources.
    ///
    /// Priority: session override > model metadata > backend capabilities > default.
    public static func resolveContextSize(
        sessionOverride: Int?,
        modelContextLength: Int?,
        backendMaxTokens: Int?,
        defaultSize: Int = 2048
    ) -> Int {
        sessionOverride ?? modelContextLength ?? backendMaxTokens ?? defaultSize
    }

    /// Trims messages to fit within the context budget.
    ///
    /// Keeps the most recent messages, trimming from the oldest. Always preserves
    /// at least the last user message even if it exceeds the budget.
    ///
    /// - Parameters:
    ///   - messages: All messages to consider, in chronological order.
    ///   - systemPrompt: Optional system prompt that consumes part of the budget.
    ///   - maxTokens: Total context window size in tokens.
    ///   - responseBuffer: Tokens reserved for the model's response.
    ///   - tokenizer: Optional tokenizer for accurate counts. Falls back to heuristic.
    /// - Returns: The subset of messages that fit within the budget.
    public static func trimMessages(
        _ messages: [ChatMessageRecord],
        systemPrompt: String?,
        maxTokens: Int,
        responseBuffer: Int = 512,
        tokenizer: TokenizerProvider? = nil
    ) -> [ChatMessageRecord] {
        guard !messages.isEmpty else { return [] }

        let systemTokens = estimateTokenCount(systemPrompt ?? "", tokenizer: tokenizer)
        let available = maxTokens - systemTokens - responseBuffer

        guard available > 0 else {
            // Budget completely consumed by system prompt — return just the last user message
            if let lastUser = messages.last(where: { $0.role == .user }) {
                return [lastUser]
            }
            return Array(messages.suffix(1))
        }

        // Walk backwards from newest, tracking the earliest index to keep.
        // Avoids building a reversed array and re-reversing it.
        var firstKeptIndex = messages.endIndex
        var usedTokens = 0

        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let messageTokens = estimateTokenCount(messages[i].content, tokenizer: tokenizer)
            if usedTokens + messageTokens > available && firstKeptIndex < messages.endIndex {
                break
            }
            firstKeptIndex = i
            usedTokens += messageTokens
        }

        return Array(messages[firstKeptIndex...])
    }

    /// Calculates a context budget breakdown.
    public static func calculateBudget(
        systemPrompt: String?,
        messages: [ChatMessageRecord],
        maxTokens: Int,
        responseBuffer: Int = 512,
        tokenizer: TokenizerProvider? = nil
    ) -> ContextBudget {
        let systemTokens = estimateTokenCount(systemPrompt ?? "", tokenizer: tokenizer)
        let messageTokens = messages.reduce(0) { $0 + estimateTokenCount($1.content, tokenizer: tokenizer) }
        let availableForHistory = maxTokens - systemTokens - responseBuffer

        return ContextBudget(
            maxTokens: maxTokens,
            systemPromptTokens: systemTokens,
            messageTokens: messageTokens,
            availableForHistory: max(0, availableForHistory),
            responseBuffer: responseBuffer
        )
    }
}

/// Breakdown of context token budget allocation.
public struct ContextBudget {
    public let maxTokens: Int
    public let systemPromptTokens: Int
    public let messageTokens: Int
    public let availableForHistory: Int
    public let responseBuffer: Int

    public init(
        maxTokens: Int,
        systemPromptTokens: Int,
        messageTokens: Int,
        availableForHistory: Int,
        responseBuffer: Int
    ) {
        self.maxTokens = maxTokens
        self.systemPromptTokens = systemPromptTokens
        self.messageTokens = messageTokens
        self.availableForHistory = availableForHistory
        self.responseBuffer = responseBuffer
    }

    /// Ratio of used tokens to max tokens (0.0 to 1.0+).
    public var usageRatio: Double {
        guard maxTokens > 0 else { return 0 }
        return Double(systemPromptTokens + messageTokens) / Double(maxTokens)
    }
}

import Foundation
import BaseChatCore
import BaseChatInference

// MARK: - ChatViewModel + Context Estimation

extension ChatViewModel {

    /// Recalculates the context usage estimate based on current messages.
    ///
    /// Uses a per-message token count cache to avoid re-estimating unchanged messages.
    func updateContextEstimate() {
        // Resolve max context: session override > model metadata > backend > default
        contextMaxTokens = ContextWindowManager.resolveContextSize(
            sessionOverride: activeSession?.contextSizeOverride,
            modelContextLength: selectedModel?.detectedContextLength,
            backendMaxTokens: backendCapabilities.map { Int($0.maxContextTokens) },
            defaultSize: 2048
        )

        // Estimate tokens for all messages + system prompt, using cache for unchanged messages.
        // Use the real tokenizer from the loaded backend when available (GGUF/llama.cpp),
        // falling back to the 4-chars/token heuristic for MLX, Foundation, and cloud.
        let activeTokenizer = inferenceService.tokenizer
        let systemTokens = ContextWindowManager.estimateTokenCount(systemPrompt, tokenizer: activeTokenizer)
        var messageTokens = 0
        var newCache: [UUID: Int] = [:]
        for message in messages {
            let count: Int
            if let cached = tokenCountCache[message.id] {
                count = cached
            } else {
                count = ContextWindowManager.estimateTokenCount(message.content, tokenizer: activeTokenizer)
            }
            newCache[message.id] = count
            messageTokens += count
        }
        tokenCountCache = newCache
        contextUsedTokens = systemTokens + messageTokens
    }
}

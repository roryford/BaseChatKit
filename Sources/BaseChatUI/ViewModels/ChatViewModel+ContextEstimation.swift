import Foundation
import BaseChatCore

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
        let systemTokens = ContextWindowManager.estimateTokenCount(systemPrompt)
        var messageTokens = 0
        var newCache: [UUID: Int] = [:]
        for message in messages {
            let count: Int
            if let cached = tokenCountCache[message.id] {
                count = cached
            } else {
                count = ContextWindowManager.estimateTokenCount(message.content)
            }
            newCache[message.id] = count
            messageTokens += count
        }
        tokenCountCache = newCache
        contextUsedTokens = systemTokens + messageTokens
    }
}

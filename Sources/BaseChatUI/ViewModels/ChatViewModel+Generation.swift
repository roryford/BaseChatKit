import Foundation
import BaseChatCore

// MARK: - ChatViewModel + Generation Core

extension ChatViewModel {

    /// Streams tokens from the inference service into an assistant message.
    ///
    /// Handles context trimming, token usage capture, empty response cleanup,
    /// and the Foundation model upgrade hint.
    func generateIntoMessage(_ assistantMessage: ChatMessageRecord) async {
        isGenerating = true
        let messageID = assistantMessage.id
        defer {
            isGenerating = false
            inferenceService.generationDidFinish()
        }

        do {
            // Build the message history, applying compression if the context is filling up.
            let allMessages = messages.filter { $0.id != messageID }
            let effectiveSystemPrompt = systemPrompt.isEmpty ? nil : systemPrompt
            let activeTokenizer = inferenceService.tokenizer

            let compressible = allMessages.map {
                CompressibleMessage(
                    id: $0.id,
                    role: $0.role.rawValue,
                    content: $0.content,
                    isPinned: pinnedMessageIDs.contains($0.id)
                )
            }

            let history: [(role: String, content: String)]
            if compressionOrchestrator.shouldCompress(
                messages: compressible,
                systemPrompt: effectiveSystemPrompt,
                contextSize: contextMaxTokens,
                tokenizer: activeTokenizer
            ) {
                let result = await compressionOrchestrator.compress(
                    messages: compressible,
                    systemPrompt: effectiveSystemPrompt,
                    contextSize: contextMaxTokens,
                    tokenizer: activeTokenizer
                )
                lastCompressionStats = result.stats
                history = result.messages
            } else {
                lastCompressionStats = nil
                let trimmed = ContextWindowManager.trimMessages(
                    allMessages,
                    systemPrompt: effectiveSystemPrompt,
                    maxTokens: contextMaxTokens,
                    responseBuffer: 512,
                    tokenizer: activeTokenizer
                )
                history = trimmed.map { (role: $0.role.rawValue, content: $0.content) }
            }

            let stream = try inferenceService.generate(
                messages: history,
                systemPrompt: effectiveSystemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty
            )

            let task = Task {
                do {
                    for try await token in stream {
                        if Task.isCancelled { break }
                        if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                            self.messages[idx].content += token
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.inference.error("Generation stream error: \(error)")
                        errorMessage = "Generation failed: \(error.localizedDescription)"
                    }
                }
            }

            generationTask = task
            await task.value

        } catch {
            Log.inference.error("Generation start error: \(error)")
            errorMessage = "Generation failed: \(error.localizedDescription)"
        }

        // Capture token usage from cloud backends.
        if let usage = inferenceService.lastTokenUsage,
           let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].promptTokens = usage.promptTokens
            messages[idx].completionTokens = usage.completionTokens
        }

        // Persist the completed assistant message.
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            if !messages[idx].content.isEmpty {
                saveMessage(messages[idx])
            } else {
                messages.remove(at: idx)
            }
        }

        // After the first assistant response on Foundation, nudge the user to
        // consider downloading a local model for longer context. Only show once
        // per session and only when Foundation is the active backend.
        let assistantContent = messages.first(where: { $0.id == messageID })?.content ?? ""
        if BaseChatConfiguration.shared.features.showUpgradeHint,
           !showUpgradeHint,
           !assistantContent.isEmpty,
           activeBackendName == "Apple",
           messages.filter({ $0.role == .assistant }).count == 1 {
            showUpgradeHint = true
            onUpgradeHintTriggered?()
        }

        updateContextEstimate()
    }
}

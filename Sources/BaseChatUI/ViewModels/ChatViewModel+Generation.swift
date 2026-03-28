import Foundation
import BaseChatCore

// MARK: - ChatViewModel + Generation Core

extension ChatViewModel {

    /// Streams tokens from the inference service into an assistant message.
    ///
    /// Handles context trimming, token usage capture, empty response cleanup,
    /// and the Foundation model upgrade hint.
    func generateIntoMessage(_ assistantMessage: ChatMessage) async {
        isGenerating = true
        defer {
            isGenerating = false
            inferenceService.generationDidFinish()
        }

        do {
            // Trim messages to fit within the context window.
            let allMessages = messages.filter { $0.id != assistantMessage.id }
            let effectiveSystemPrompt = systemPrompt.isEmpty ? nil : systemPrompt
            let trimmedMessages = ContextWindowManager.trimMessages(
                allMessages,
                systemPrompt: effectiveSystemPrompt,
                maxTokens: contextMaxTokens,
                responseBuffer: 512
            )
            let history = trimmedMessages.map { (role: $0.role.rawValue, content: $0.content) }

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
                        assistantMessage.content += token
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
        if let usage = inferenceService.lastTokenUsage {
            assistantMessage.promptTokens = usage.promptTokens
            assistantMessage.completionTokens = usage.completionTokens
        }

        // Persist the completed assistant message.
        if !assistantMessage.content.isEmpty {
            saveMessage(assistantMessage)
        } else {
            // Empty response — remove the placeholder using ID-based lookup
            // to avoid index invalidation from concurrent modifications.
            messages.removeAll { $0.id == assistantMessage.id }
        }

        // After the first assistant response on Foundation, nudge the user to
        // consider downloading a local model for longer context. Only show once
        // per session and only when Foundation is the active backend.
        if !showUpgradeHint,
           !assistantMessage.content.isEmpty,
           activeBackendName == "Apple",
           messages.filter({ $0.role == .assistant }).count == 1 {
            showUpgradeHint = true
            onUpgradeHintTriggered?()
        }

        updateContextEstimate()
    }
}

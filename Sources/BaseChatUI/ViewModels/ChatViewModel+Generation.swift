import Foundation
import BaseChatCore

// MARK: - ChatViewModel + Generation Core

/// Buffers streamed tokens and emits coalesced batches to reduce high-frequency
/// observable mutations that would otherwise trigger excessive SwiftUI re-renders.
struct StreamingTokenBatcher {
    private let interval: Duration
    private let maxBufferedCharacters: Int
    private var buffered = ""
    private var lastFlush: ContinuousClock.Instant

    init(
        interval: Duration,
        maxBufferedCharacters: Int,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        self.interval = interval
        self.maxBufferedCharacters = maxBufferedCharacters
        self.lastFlush = now
    }

    mutating func append(_ token: String, now: ContinuousClock.Instant) -> String? {
        buffered += token
        guard shouldFlush(now: now) else { return nil }
        return flush(now: now)
    }

    mutating func flush(now: ContinuousClock.Instant) -> String? {
        guard !buffered.isEmpty else { return nil }
        let batch = buffered
        buffered = ""
        lastFlush = now
        return batch
    }

    private func shouldFlush(now: ContinuousClock.Instant) -> Bool {
        buffered.count >= maxBufferedCharacters || now - lastFlush >= interval
    }
}

extension ChatViewModel {

    /// Streams tokens from the inference service into an assistant message.
    ///
    /// Handles context trimming, token usage capture, empty response cleanup,
    /// and the Foundation model upgrade hint.
    func generateIntoMessage(_ assistantMessage: ChatMessageRecord) async {
        backgroundTaskError = nil
        activityPhase = .waitingForFirstToken
        let messageID = assistantMessage.id
        defer {
            activityPhase = .idle
            inferenceService.generationDidFinish()
        }

        do {
            // Build the message history, applying compression if the context is filling up.
            let allMessages = messages.filter { $0.id != messageID }
            let rawSystemPrompt = systemPrompt.isEmpty ? nil : systemPrompt
            let effectiveSystemPrompt: String?
            if let rawSystemPrompt, macroExpansionEnabled {
                effectiveSystemPrompt = MacroExpander.expand(rawSystemPrompt, context: buildMacroContext())
            } else {
                effectiveSystemPrompt = rawSystemPrompt
            }
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

            var tokenCount = 0
            let task = Task {
                var batcher = StreamingTokenBatcher(
                    interval: streamingUpdateInterval,
                    maxBufferedCharacters: streamingBatchCharacterLimit
                )

                do {
                    for try await token in stream {
                        if Task.isCancelled { break }
                        tokenCount += 1
                        if tokenCount == 1 {
                            self.activityPhase = .streaming
                        }
                        if let batch = batcher.append(token, now: ContinuousClock.now),
                           let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                            self.messages[idx].content += batch
                            if self.loopDetectionEnabled,
                               self.messages[idx].content.count >= 100,
                               RepetitionDetector.looksLikeLooping(self.messages[idx].content) {
                                self.inferenceService.stopGeneration()
                                self.errorMessage = "Generation stopped: the model appears to be repeating itself."
                                break
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.inference.error("Generation stream error: \(error)")
                        self.surfaceError(error, kind: .generation, context: "Generation failed")
                    }
                }

                // Flush remaining buffered tokens after stream ends (normal, error, or cancellation).
                if let batch = batcher.flush(now: ContinuousClock.now),
                   let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[idx].content += batch
                }
            }

            generationTask = task
            await task.value

        } catch {
            Log.inference.error("Generation start error: \(error)")
            surfaceError(error, kind: .generation, context: "Generation failed")
        }

        // Capture token usage from cloud backends.
        if let usage = inferenceService.lastTokenUsage,
           let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].promptTokens = usage.promptTokens
            messages[idx].completionTokens = usage.completionTokens
        }

        // Persist the completed assistant message.
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            do {
                if messages[idx].content.isEmpty {
                    messages.remove(at: idx)
                } else {
                    try saveMessage(messages[idx])
                }
            } catch {
                Log.persistence.error("Failed to persist assistant message: \(error)")
                surfaceError(error, kind: .persistence, context: "Failed to save assistant response")
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

        // Fire post-generation tasks off @MainActor if we have a non-empty assistant message.
        if let completedMessage = messages.first(where: { $0.id == messageID }),
           !completedMessage.content.isEmpty,
           let session = activeSession {
            runPostGenerationTasks(message: completedMessage, session: session)
        }
    }

    /// Launches post-generation tasks sequentially off `@MainActor`.
    ///
    /// A throwing task records its error in ``backgroundTaskError`` and execution
    /// continues with the next task. Cancellation via ``backgroundTask`` exits the loop.
    private func runPostGenerationTasks(message: ChatMessageRecord, session: ChatSessionRecord) {
        let tasks = postGenerationTasks
        guard !tasks.isEmpty else { return }

        backgroundTask = Task { [weak self, tasks, message, session] in
            for task in tasks {
                guard !Task.isCancelled else { break }
                do {
                    try await task.run(message: message, session: session)
                } catch is CancellationError {
                    break
                } catch {
                    self?.backgroundTaskError = error
                }
            }
        }
    }

    /// Builds a complete `MacroContext` by merging user-supplied values with
    /// auto-derived values from the current conversation.
    private func buildMacroContext() -> MacroContext {
        var ctx = macroContext
        if ctx.lastMessage == nil {
            ctx.lastMessage = messages.last(where: { $0.role == .user || $0.role == .assistant })?.content
        }
        if ctx.lastUserMessage == nil {
            ctx.lastUserMessage = messages.last(where: { $0.role == .user })?.content
        }
        if ctx.lastCharMessage == nil {
            ctx.lastCharMessage = messages.last(where: { $0.role == .assistant })?.content
        }
        return ctx
    }
}

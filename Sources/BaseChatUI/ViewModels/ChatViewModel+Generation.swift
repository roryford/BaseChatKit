import Foundation
import BaseChatCore
import BaseChatInference

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

// File-private top-level — nonisolated, initialized once, thread-safe.
// Kept outside the @MainActor-isolated ChatViewModel extension so that
// nonisolated `applySystemPromptContext` can access it without a Swift 6
// actor-isolation warning.
private let _systemPromptContextRegex: NSRegularExpression = {
    // Force-unwrap is safe: the pattern is a compile-time constant with no user input.
    try! NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#, options: [])
}()

extension ChatViewModel {

    /// Looks up a message by ID and applies a mutation in a single step,
    /// ensuring the index is never stale. Returns `true` if the message was found.
    @discardableResult
    func mutateMessage(id: UUID, _ body: (inout ChatMessageRecord) -> Void) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return false }
        body(&messages[idx])
        return true
    }

    /// Streams tokens from the inference service into an assistant message.
    ///
    /// Handles context trimming, token usage capture, empty response cleanup,
    /// and the Foundation model upgrade hint.
    func generateIntoMessage(_ assistantMessage: ChatMessageRecord) async {
        backgroundTaskError = nil
        transitionPhase(to: .waitingForFirstToken)
        let messageID = assistantMessage.id
        defer {
            // Only update state if we actually started a generation. If enqueue()
            // threw (e.g. queue full), activeGenerationToken is nil and we should
            // not touch anyone else's active request.
            if activeGenerationToken != nil {
                let willDrainNext = inferenceService.hasQueuedRequests
                activeGenerationToken = nil
                // The queue auto-drains when the stream terminates in InferenceService.
                // Only go idle if no queued request was waiting to start.
                // Check before drain, since drain may empty the queue while
                // starting a new generation.
                if !willDrainNext {
                    transitionPhase(to: .idle)
                }
            } else {
                transitionPhase(to: .idle)
            }
        }

        do {
            // Build the message history, trimming to fit the context window.
            let allMessages = messages.filter { $0.id != messageID }
            let rawSystemPrompt = systemPrompt.isEmpty ? nil : systemPrompt
            let effectiveSystemPrompt: String? = rawSystemPrompt.map { prompt in
                Self.applySystemPromptContext(prompt, context: systemPromptContext)
            }
            // Reuse the persistent caching tokenizer — token counts for unchanged
            // messages carry over between generation cycles.
            let cachingTokenizer: TokenizerProvider = reusableCachingTokenizer

            let trimmed = ContextWindowManager.trimMessages(
                allMessages,
                systemPrompt: effectiveSystemPrompt,
                maxTokens: contextMaxTokens,
                responseBuffer: 512,
                tokenizer: cachingTokenizer
            )
            let history: [(role: String, content: String)] = trimmed.map {
                (role: $0.role.rawValue, content: $0.content)
            }

            let (token, stream) = try inferenceService.enqueue(
                messages: history,
                systemPrompt: effectiveSystemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                priority: .userInitiated,
                sessionID: activeSessionID
            )
            activeGenerationToken = token

            var tokenCount = 0
            // GenerationStream.phase tracks backend-level lifecycle (connecting, streaming, stalled, retrying).
            // ChatViewModel.activityPhase tracks UI-level state (waitingForFirstToken, streaming, idle).
            // These are intentionally separate: activityPhase drives UI chrome, stream.phase drives
            // reliability indicators. A future PR may unify them.
            let task = Task {
                var batcher = StreamingTokenBatcher(
                    interval: streamingUpdateInterval,
                    maxBufferedCharacters: streamingBatchCharacterLimit
                )
                var consumer = GenerationStreamConsumer(loopDetectionEnabled: self.loopDetectionEnabled)

                do {
                    eventLoop: for try await event in stream.events {
                        if Task.isCancelled { break }

                        switch consumer.handle(event) {
                        case .appendText(let token):
                            tokenCount += 1
                            if tokenCount == 1 {
                                self.transitionPhase(to: .streaming)
                            }
                            if let batch = batcher.append(token, now: ContinuousClock.now) {
                                var looping = false
                                self.mutateMessage(id: messageID) { msg in
                                    msg.content += batch
                                    if consumer.shouldStopForLoop(content: msg.content) {
                                        looping = true
                                    }
                                }
                                if looping {
                                    self.inferenceService.stopGeneration()
                                    self.errorMessage = "Generation stopped: the model appears to be repeating itself."
                                    break eventLoop
                                }
                            }

                        case .recordUsage(let prompt, let completion):
                            self.mutateMessage(id: messageID) { msg in
                                msg.promptTokens = prompt
                                msg.completionTokens = completion
                            }

                        case .dispatchToolCall:
                            // Tool execution is a host-app concern; ChatViewModel does not
                            // implement a tool dispatch loop. Apps that need tool calling
                            // should drive generation directly via InferenceService.
                            break

                        case .appendThinkingText, .finalizeThinking:
                            // Thinking rendering is a Phase 2 concern; ChatViewModel defers
                            // to host apps that opt in to thinking display.
                            break
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.inference.error("Generation stream error: \(error)")
                        self.surfaceError(error, kind: .generation, context: "Generation failed")
                    }
                }

                // Flush remaining buffered tokens after stream ends (normal, error, or cancellation).
                if let batch = batcher.flush(now: ContinuousClock.now) {
                    self.mutateMessage(id: messageID) { $0.content += batch }
                }
            }

            generationTask = task
            await task.value

        } catch {
            Log.inference.error("Generation start error: \(error)")
            surfaceError(error, kind: .generation, context: "Generation failed")
        }

        // Capture token usage from cloud backends.
        if let usage = inferenceService.lastTokenUsage {
            mutateMessage(id: messageID) { msg in
                msg.promptTokens = usage.promptTokens
                msg.completionTokens = usage.completionTokens
            }
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

    /// Substitutes `{{key}}` tokens in `text` with values from `context`.
    ///
    /// Single-pass scan: each `{{word}}` token in the source is examined exactly
    /// once, so substitution is non-recursive (a value containing `{{otherKey}}`
    /// is not re-expanded) and the result does not depend on dictionary
    /// iteration order. Tokens whose key is not present in `context` are left
    /// untouched, mirroring the pass-through behavior documented on
    /// ``systemPromptContext``.
    static func applySystemPromptContext(_ text: String, context: [String: String]) -> String {
        guard !context.isEmpty, text.contains("{{") else { return text }
        // `{{word}}` where `word` is one or more word characters. Anything that
        // doesn't match (whitespace, dots, empty `{{}}`) is ignored.
        let regex = _systemPromptContextRegex
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        // Walk matches in reverse so replacement ranges remain valid as we mutate.
        let matches = regex.matches(in: text, options: [], range: fullRange).reversed()
        var result = text
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: result),
                  let fullMatchRange = Range(match.range, in: result) else { continue }
            let key = String(result[keyRange])
            if let replacement = context[key] {
                result.replaceSubrange(fullMatchRange, with: replacement)
            }
        }
        return result
    }

}

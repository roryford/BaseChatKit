import Foundation
import BaseChatCore
import BaseChatInference

// MARK: - StreamingTokenBatcher

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
// Kept outside the @MainActor-isolated GenerationCoordinator so that
// nonisolated `applySystemPromptContext` can access it without a Swift 6
// actor-isolation warning.
private let _systemPromptContextRegex: NSRegularExpression = {
    // Force-unwrap is safe: the pattern is a compile-time constant with no user input.
    try! NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#, options: [])
}()

// MARK: - GenerationCoordinator

/// Owns the token-streaming loop extracted from `ChatViewModel` (phase 4 of #329).
///
/// The coordinator is `@MainActor` but NOT `@Observable` — it holds no
/// SwiftUI-observed state of its own. All observable side-effects are routed
/// back to `ChatViewModel` through the callback seams set at construction.
@MainActor
final class GenerationCoordinator {

    // MARK: - Read Seams

    /// Returns the current snapshot of messages (all messages, not filtered).
    var messages: () -> [ChatMessageRecord] = { [] }

    /// Returns the current system prompt string.
    var systemPrompt: () -> String = { "" }

    /// Returns the current system prompt context dictionary.
    var systemPromptContext: () -> [String: String] = { [:] }

    /// Returns the current max token budget.
    var contextMaxTokens: () -> Int = { 2048 }

    /// Returns the current temperature setting.
    var temperature: () -> Float = { 0.7 }

    /// Returns the current top-P setting.
    var topP: () -> Float = { 0.9 }

    /// Returns the current repeat penalty setting.
    var repeatPenalty: () -> Float = { 1.0 }

    /// Returns the active session ID, or nil if no session is selected.
    var activeSessionID: () -> UUID? = { nil }

    /// Returns whether loop detection is enabled.
    var loopDetectionEnabled: () -> Bool = { true }

    /// Returns the streaming update interval.
    var streamingUpdateInterval: () -> Duration = { .milliseconds(33) }

    /// Returns the streaming batch character limit.
    var streamingBatchCharacterLimit: () -> Int = { 128 }

    /// Returns the active backend name, or nil if none.
    var activeBackendName: () -> String? = { nil }

    /// Returns the active session record, or nil.
    var activeSession: () -> ChatSessionRecord? = { nil }

    /// Returns the registered post-generation tasks.
    var postGenerationTasks: () -> [any PostGenerationTask] = { [] }

    /// Returns the reusable caching tokenizer.
    var reusableCachingTokenizer: () -> CachingTokenizer

    /// Returns whether the upgrade hint has already been shown.
    var showUpgradeHint: () -> Bool = { false }

    // MARK: - Write-back Seams

    /// Forwards to `ChatViewModel.transitionPhase(to:)`. Returns `true` if accepted.
    var onTransitionPhase: (BackendActivityPhase) -> Bool = { _ in false }

    /// Surfaces a structured error on the view model.
    var onSurfaceError: (any Error, ChatError.Kind, String?) -> Void = { _, _, _ in }

    /// Sets `ChatViewModel.errorMessage` to an optional string.
    var onSetErrorMessage: (String?) -> Void = { _ in }

    /// Forwards to `ChatViewModel.mutateMessage(id:_:)`.
    var onMutateMessage: (UUID, (inout ChatMessageRecord) -> Void) -> Void = { _, _ in }

    /// Sets `ChatViewModel.activeGenerationToken`.
    var onSetActiveGenerationToken: (InferenceService.GenerationRequestToken?) -> Void = { _ in }

    /// Sets `ChatViewModel.generationTask`.
    var onSetGenerationTask: (Task<Void, Never>?) -> Void = { _ in }

    /// Sets `ChatViewModel.backgroundTask`.
    var onSetBackgroundTask: (Task<Void, Never>?) -> Void = { _ in }

    /// Sets `ChatViewModel.backgroundTaskError`.
    var onSetBackgroundTaskError: (Error?) -> Void = { _ in }

    /// Sets `ChatViewModel.showUpgradeHint`.
    var onSetShowUpgradeHint: (Bool) -> Void = { _ in }

    /// Called when the upgrade hint is first triggered. Optional.
    var onUpgradeHintTriggered: (() -> Void)?

    /// Triggers a context estimate update on the view model.
    var onUpdateContextEstimate: () -> Void = {}

    /// Persists a completed message.
    var onSaveMessage: (ChatMessageRecord) throws -> Void = { _ in }

    /// Removes an assistant message from the view model (called for empty responses).
    var onRemoveMessage: (UUID) -> Void = { _ in }

    // MARK: - Dependencies

    private let inferenceService: InferenceService

    // MARK: - Init

    init(
        inferenceService: InferenceService,
        reusableCachingTokenizer: @escaping () -> CachingTokenizer
    ) {
        self.inferenceService = inferenceService
        self.reusableCachingTokenizer = reusableCachingTokenizer
    }

    // MARK: - Public Interface

    /// Streams tokens from the inference service into an assistant message.
    ///
    /// Handles context trimming, token usage capture, empty response cleanup,
    /// and the Foundation model upgrade hint.
    func generate(into assistantMessage: ChatMessageRecord) async {
        onSetBackgroundTaskError(nil)
        _ = onTransitionPhase(.waitingForFirstToken)
        let messageID = assistantMessage.id
        var didEnqueue = false
        defer {
            // Only update state if we actually started a generation. If enqueue()
            // threw (e.g. queue full), activeGenerationToken is nil and we should
            // not touch anyone else's active request.
            if didEnqueue {
                let willDrainNext = inferenceService.hasQueuedRequests
                onSetActiveGenerationToken(nil)
                // The queue auto-drains when the stream terminates in InferenceService.
                // Only go idle if no queued request was waiting to start.
                // Check before drain, since drain may empty the queue while
                // starting a new generation.
                if !willDrainNext {
                    _ = onTransitionPhase(.idle)
                }
            } else {
                _ = onTransitionPhase(.idle)
            }
        }

        do {
            // Build the message history, trimming to fit the context window.
            let allMessages = messages().filter { $0.id != messageID }
            let rawSystemPrompt = systemPrompt().isEmpty ? nil : systemPrompt()
            let effectiveSystemPrompt: String? = rawSystemPrompt.map { prompt in
                Self.applySystemPromptContext(prompt, context: systemPromptContext())
            }
            // Reuse the persistent caching tokenizer — token counts for unchanged
            // messages carry over between generation cycles.
            let cachingTokenizer: TokenizerProvider = reusableCachingTokenizer()

            let trimmed = ContextWindowManager.trimMessages(
                allMessages,
                systemPrompt: effectiveSystemPrompt,
                maxTokens: contextMaxTokens(),
                responseBuffer: 512,
                tokenizer: cachingTokenizer
            )
            let history: [(role: String, content: String)] = trimmed.map {
                (role: $0.role.rawValue, content: $0.content)
            }

            let (token, stream) = try inferenceService.enqueue(
                messages: history,
                systemPrompt: effectiveSystemPrompt,
                temperature: temperature(),
                topP: topP(),
                repeatPenalty: repeatPenalty(),
                priority: .userInitiated,
                sessionID: activeSessionID()
            )
            onSetActiveGenerationToken(token)
            didEnqueue = true

            var tokenCount = 0
            // GenerationStream.phase tracks backend-level lifecycle (connecting, streaming, stalled, retrying).
            // ChatViewModel.activityPhase tracks UI-level state (waitingForFirstToken, streaming, idle).
            // These are intentionally separate: activityPhase drives UI chrome, stream.phase drives
            // reliability indicators. A future PR may unify them.
            let task = Task { [weak self] in
                guard let self else { return }
                var batcher = StreamingTokenBatcher(
                    interval: self.streamingUpdateInterval(),
                    maxBufferedCharacters: self.streamingBatchCharacterLimit()
                )
                var consumer = GenerationStreamConsumer(loopDetectionEnabled: self.loopDetectionEnabled())
                var thinkingAccumulator = ""

                do {
                    eventLoop: for try await event in stream.events {
                        if Task.isCancelled { break }

                        switch consumer.handle(event) {
                        case .appendText(let token):
                            tokenCount += 1
                            if tokenCount == 1 {
                                _ = self.onTransitionPhase(.streaming)
                            }
                            if let batch = batcher.append(token, now: ContinuousClock.now) {
                                var looping = false
                                self.onMutateMessage(messageID) { msg in
                                    msg.content += batch
                                    if consumer.shouldStopForLoop(content: msg.content) {
                                        looping = true
                                    }
                                }
                                if looping {
                                    self.inferenceService.stopGeneration()
                                    self.onSetErrorMessage("Generation stopped: the model appears to be repeating itself.")
                                    break eventLoop
                                }
                            }

                        case .recordUsage(let prompt, let completion):
                            self.onMutateMessage(messageID) { msg in
                                msg.promptTokens = prompt
                                msg.completionTokens = completion
                            }

                        case .dispatchToolCall:
                            // Tool execution is a host-app concern; ChatViewModel does not
                            // implement a tool dispatch loop. Apps that need tool calling
                            // should drive generation directly via InferenceService.
                            break

                        case .appendThinkingText(let text):
                            let isFirstThinkingFragment = thinkingAccumulator.isEmpty
                            thinkingAccumulator += text
                            if isFirstThinkingFragment {
                                // Insert a placeholder `.thinking("")` part immediately so the
                                // UI can render the "Thinking…" label during the reasoning phase
                                // rather than staying on the generic typing placeholder.
                                self.onMutateMessage(messageID) { msg in
                                    if msg.contentParts.firstIndex(where: { $0.thinkingContent != nil }) == nil {
                                        let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? 0
                                        msg.contentParts.insert(.thinking(""), at: insertAt)
                                    }
                                }
                            }

                        case .finalizeThinking:
                            let block = thinkingAccumulator
                            thinkingAccumulator = ""
                            guard !block.isEmpty else { break }
                            self.onMutateMessage(messageID) { msg in
                                // Append to any existing thinking part so multiple <think>…</think>
                                // blocks within one response are concatenated into a single part.
                                if let idx = msg.contentParts.firstIndex(where: { $0.thinkingContent != nil }) {
                                    let existing = msg.contentParts[idx].thinkingContent ?? ""
                                    msg.contentParts[idx] = .thinking(existing.isEmpty ? block : existing + "\n\n" + block)
                                } else {
                                    let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? 0
                                    msg.contentParts.insert(.thinking(block), at: insertAt)
                                }
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.inference.error("Generation stream error: \(error)")
                        self.onSurfaceError(error, .generation, "Generation failed")
                    }
                }

                // Flush remaining buffered tokens after stream ends (normal, error, or cancellation).
                if let batch = batcher.flush(now: ContinuousClock.now) {
                    self.onMutateMessage(messageID) { $0.content += batch }
                }

                // Finalize an unclosed thinking block — a model may emit <think>…
                // without a closing tag if generation is cut short.
                if !thinkingAccumulator.isEmpty {
                    let block = thinkingAccumulator
                    thinkingAccumulator = ""
                    self.onMutateMessage(messageID) { msg in
                        if let idx = msg.contentParts.firstIndex(where: { $0.thinkingContent != nil }) {
                            let existing = msg.contentParts[idx].thinkingContent ?? ""
                            msg.contentParts[idx] = .thinking(existing.isEmpty ? block : existing + "\n\n" + block)
                        } else {
                            let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? 0
                            msg.contentParts.insert(.thinking(block), at: insertAt)
                        }
                    }
                }
            }

            onSetGenerationTask(task)
            await task.value

        } catch {
            Log.inference.error("Generation start error: \(error)")
            onSurfaceError(error, .generation, "Generation failed")
        }

        // Capture token usage from cloud backends.
        if let usage = inferenceService.lastTokenUsage {
            onMutateMessage(messageID) { msg in
                msg.promptTokens = usage.promptTokens
                msg.completionTokens = usage.completionTokens
            }
        }

        // Persist the completed assistant message.
        // Keep the message if it has visible text OR thinking content — a thinking-only
        // response (no visible text but `.thinking` parts present) is still meaningful.
        let currentMessages = messages()
        if let idx = currentMessages.firstIndex(where: { $0.id == messageID }) {
            let hasThinkingContent = currentMessages[idx].contentParts.contains(where: { $0.thinkingContent != nil })
            do {
                if !currentMessages[idx].hasVisibleContent && !hasThinkingContent {
                    onRemoveMessage(messageID)
                } else {
                    try onSaveMessage(currentMessages[idx])
                }
            } catch {
                Log.persistence.error("Failed to persist assistant message: \(error)")
                onSurfaceError(error, .persistence, "Failed to save assistant response")
            }
        }

        // After the first assistant response on Foundation, nudge the user to
        // consider downloading a local model for longer context. Only show once
        // per session and only when Foundation is the active backend.
        if BaseChatConfiguration.shared.features.showUpgradeHint,
           !showUpgradeHint(),
           messages().first(where: { $0.id == messageID })?.hasVisibleContent == true,
           activeBackendName() == "Apple",
           messages().filter({ $0.role == .assistant }).count == 1 {
            onSetShowUpgradeHint(true)
            onUpgradeHintTriggered?()
        }

        onUpdateContextEstimate()

        // Fire post-generation tasks off @MainActor if we have a non-empty assistant message.
        if let completedMessage = messages().first(where: { $0.id == messageID }),
           completedMessage.hasVisibleContent,
           let session = activeSession() {
            runPostGenerationTasks(message: completedMessage, session: session)
        }
    }

    // MARK: - Private Helpers

    /// Launches post-generation tasks sequentially off `@MainActor`.
    ///
    /// A throwing task records its error in ``backgroundTaskError`` and execution
    /// continues with the next task. Cancellation via ``backgroundTask`` exits the loop.
    private func runPostGenerationTasks(message: ChatMessageRecord, session: ChatSessionRecord) {
        let tasks = postGenerationTasks()
        guard !tasks.isEmpty else { return }

        let bgTask = Task { [weak self, tasks, message, session] in
            for task in tasks {
                guard !Task.isCancelled else { break }
                do {
                    try await task.run(message: message, session: session)
                } catch is CancellationError {
                    break
                } catch {
                    self?.onSetBackgroundTaskError(error)
                }
            }
        }
        onSetBackgroundTask(bgTask)
    }

    /// Substitutes `{{key}}` tokens in `text` with values from `context`.
    ///
    /// Single-pass scan: each `{{word}}` token in the source is examined exactly
    /// once, so substitution is non-recursive (a value containing `{{otherKey}}`
    /// is not re-expanded) and the result does not depend on dictionary
    /// iteration order. Tokens whose key is not present in `context` are left
    /// untouched, mirroring the pass-through behavior documented on
    /// ``ChatViewModel/systemPromptContext``.
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

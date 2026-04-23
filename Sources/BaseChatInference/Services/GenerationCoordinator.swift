import Foundation
import Observation

/// Owns the generation queue, in-flight request tracking, prompt formatting,
/// and generation lifecycle management.
///
/// This is an internal implementation detail of `BaseChatInference`.
/// `InferenceService` delegates all generation operations to this coordinator
/// and preserves the unchanged public API.
@Observable
@MainActor
final class GenerationCoordinator {

    // MARK: - Published State

    /// Whether the coordinator has an active generation in progress.
    ///
    /// `internal` storage, exposed as `public` via `InferenceService.isGenerating`.
    private(set) var isGenerating = false

    // MARK: - Dependencies

    weak var provider: (any GenerationContextProvider)?

    /// Injected reader for the current thermal state.
    ///
    /// Defaults to `ProcessInfo.processInfo.thermalState`. Tests override this
    /// to exercise the background-priority thermal-drop branch deterministically
    /// without `@testable import` or `#if DEBUG` hooks. `@Sendable` and
    /// non-isolated so it is safe under Swift 6 strict concurrency.
    private let thermalStateProvider: @Sendable () -> ProcessInfo.ThermalState

    /// Optional registry used to dispatch model-emitted ``ToolCall`` events.
    ///
    /// Stored here in wave 1 so the coordinator's init surface is stable for
    /// downstream wiring; the actual dispatch site lands in wave 2 Agent D.
    let toolRegistry: ToolRegistry?

    /// Gate consulted before dispatching every ``ToolCall`` through
    /// ``toolRegistry``. Defaults to ``AutoApproveGate`` so hosts that have
    /// not opted into per-call approval see unchanged behaviour.
    ///
    /// The gate is invoked on the *finalized* ``ToolCall`` — streaming
    /// argument deltas are merged by the backend before the coordinator
    /// observes the call event. On ``ToolApprovalDecision/denied(reason:)``
    /// the coordinator synthesises a ``ToolResult`` with
    /// ``ToolResult/ErrorKind/permissionDenied`` and continues the stream
    /// rather than cancelling generation.
    let toolApprovalGate: any ToolApprovalGate

    // MARK: - Test Seam

    /// Test-only hook invoked alongside `Log.inference.warning` when
    /// `jsonMode=true` is requested on a backend whose capabilities report
    /// `supportsNativeJSONMode == false`. Receives `(backendTypeName, message)`.
    ///
    /// Production callers never set this; it exists so unit tests can verify
    /// the silent-ignore warning is emitted without standing up an OSLogStore
    /// reader. Tests must reset it in `tearDown` to avoid cross-test leakage.
    nonisolated(unsafe) static var jsonModeUnsupportedWarningHook: (@Sendable (String, String) -> Void)?

    // MARK: - Queue Types (Private)

    private struct QueuedRequest {
        let token: GenerationRequestToken
        let priority: GenerationPriority
        let sessionID: UUID?
        let messages: [(role: String, content: String)]
        let systemPrompt: String?
        let config: GenerationConfig
        let stream: GenerationStream
    }

    // MARK: - Queue State (Private)

    private var nextGenerationToken: GenerationRequestToken = .zero
    private var requestQueue: [QueuedRequest] = []
    private var activeRequest: QueuedRequest?
    private var activeTask: Task<Void, Never>?
    private var continuations: [GenerationRequestToken: AsyncThrowingStream<GenerationEvent, Error>.Continuation] = [:]
    private let maxQueueDepth = 8

    // MARK: - Computed

    var hasQueuedRequests: Bool { !requestQueue.isEmpty }

    var lastTokenUsage: (promptTokens: Int, completionTokens: Int)? {
        (provider?.currentBackend as? TokenUsageProvider)?.lastUsage
    }

    // MARK: - Initializers

    nonisolated init(
        thermalStateProvider: @Sendable @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        toolRegistry: ToolRegistry? = nil,
        toolApprovalGate: any ToolApprovalGate = AutoApproveGate()
    ) {
        self.thermalStateProvider = thermalStateProvider
        self.toolRegistry = toolRegistry
        self.toolApprovalGate = toolApprovalGate
    }

    // MARK: - Generation (Non-Queued)

    /// Generates text from a message history, streaming tokens via the active backend.
    ///
    /// This is the low-level, non-queued entry point. It does **not** participate
    /// in the generation queue.
    ///
    /// When the backend conforms to ``TokenCountingBackend``, an exact token count
    /// of the assembled prompt is taken before the C-level call. If the prompt
    /// exceeds `effectiveContextSize - maxOutputTokens`, the oldest non-system
    /// messages are trimmed one pair at a time and the prompt is re-assembled,
    /// up to `maxTrimAttempts` times. If the prompt still doesn't fit after
    /// trimming, ``InferenceError/contextExhausted(promptTokens:maxOutputTokens:contextSize:)``
    /// is thrown — the overflow never reaches the C layer.
    func generate(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false
    ) throws -> GenerationStream {
        guard let backend = provider?.currentBackend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        // Single pre-dispatch chokepoint for the native-JSON-mode capability
        // check. Backends without native JSON-mode support silently ignore
        // the flag and return plain text, so we warn once per request here
        // rather than in each backend. Callers can branch on
        // `backend.capabilities.supportsNativeJSONMode` programmatically to
        // suppress the warning by not setting the flag in the first place.
        if jsonMode && !backend.capabilities.supportsNativeJSONMode {
            let backendType = String(describing: type(of: backend))
            let message = "GenerationCoordinator: jsonMode=true requested but \(backendType) does not support native JSON mode (capabilities.supportsNativeJSONMode == false); the flag will be ignored and the response will be plain text. Check `backend.capabilities.supportsNativeJSONMode` before setting `config.jsonMode`."
            Log.inference.warning("\(message, privacy: .public)")
            Self.jsonModeUnsupportedWarningHook?(backendType, message)
        }

        var config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens,
            jsonMode: jsonMode
        )
        config.maxThinkingTokens = maxThinkingTokens

        // Exact-count pre-flight: backends that conform to TokenCountingBackend
        // expose the real tokenizer. Use it to verify the assembled prompt fits
        // inside the context window before committing to the C-level decode.
        // The heuristic guard inside LlamaBackend.generate() remains as a
        // fast-path sanity check for obviously-too-large prompts, but this
        // trim-and-retry loop is the definitive gate that prevents KV overflow.
        if let counter = backend as? TokenCountingBackend,
           backend.capabilities.requiresPromptTemplate {
            let result = try exactPreflightAndTrim(
                counter: counter,
                backend: backend,
                messages: messages,
                systemPrompt: systemPrompt,
                config: config
            )
            if let historyReceiver = backend as? ConversationHistoryReceiver {
                // Pass the trimmed messages so the backend's own history buffer
                // reflects what was actually sent in the prompt.
                historyReceiver.setConversationHistory(result.trimmedMessages)
            }
            return try backend.generate(
                prompt: result.prompt,
                systemPrompt: nil,
                config: config
            )
        }

        // Non-TokenCountingBackend path: assemble prompt and forward.
        // For backends that require a prompt template, messages are formatted
        // into a single string. Otherwise the most recent user message is
        // passed directly and the system prompt goes through a separate channel.
        let assembledPrompt: String
        let effectiveSystemPrompt: String?

        if backend.capabilities.requiresPromptTemplate {
            let template = provider?.selectedPromptTemplate ?? .chatML
            assembledPrompt = template.format(messages: messages, systemPrompt: systemPrompt)
            effectiveSystemPrompt = nil
        } else {
            assembledPrompt = messages.last(where: { $0.role == "user" })?.content ?? ""
            effectiveSystemPrompt = systemPrompt
        }

        if let historyReceiver = backend as? ConversationHistoryReceiver {
            historyReceiver.setConversationHistory(messages)
        }

        return try backend.generate(
            prompt: assembledPrompt,
            systemPrompt: effectiveSystemPrompt,
            config: config
        )
    }

    // MARK: - Generation (Config-preserving entry for tool-dispatch)

    /// Generates from a message history using a caller-supplied
    /// ``GenerationConfig``, preserving every field including `tools`,
    /// `toolChoice`, and `maxToolIterations`.
    ///
    /// The primary `generate(messages:...)` entry reconstructs a config from
    /// individual parameters, which drops the tool-related fields. The
    /// tool-dispatch loop in `drainQueue` uses this entry instead so the
    /// backend sees the full config authored by the caller.
    func generateWithConfig(
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard let backend = provider?.currentBackend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        if config.jsonMode && !backend.capabilities.supportsNativeJSONMode {
            let backendType = String(describing: type(of: backend))
            let message = "GenerationCoordinator: jsonMode=true requested but \(backendType) does not support native JSON mode (capabilities.supportsNativeJSONMode == false); the flag will be ignored and the response will be plain text. Check `backend.capabilities.supportsNativeJSONMode` before setting `config.jsonMode`."
            Log.inference.warning("\(message, privacy: .public)")
            Self.jsonModeUnsupportedWarningHook?(backendType, message)
        }

        if let counter = backend as? TokenCountingBackend,
           backend.capabilities.requiresPromptTemplate {
            let result = try exactPreflightAndTrim(
                counter: counter,
                backend: backend,
                messages: messages,
                systemPrompt: systemPrompt,
                config: config
            )
            if let historyReceiver = backend as? ConversationHistoryReceiver {
                historyReceiver.setConversationHistory(result.trimmedMessages)
            }
            return try backend.generate(
                prompt: result.prompt,
                systemPrompt: nil,
                config: config
            )
        }

        let assembledPrompt: String
        let effectiveSystemPrompt: String?
        if backend.capabilities.requiresPromptTemplate {
            let template = provider?.selectedPromptTemplate ?? .chatML
            assembledPrompt = template.format(messages: messages, systemPrompt: systemPrompt)
            effectiveSystemPrompt = nil
        } else {
            assembledPrompt = messages.last(where: { $0.role == "user" })?.content ?? ""
            effectiveSystemPrompt = systemPrompt
        }

        if let historyReceiver = backend as? ConversationHistoryReceiver {
            historyReceiver.setConversationHistory(messages)
        }

        return try backend.generate(
            prompt: assembledPrompt,
            systemPrompt: effectiveSystemPrompt,
            config: config
        )
    }

    // MARK: - Exact Pre-flight (Private)

    private struct ExactPreflightResult {
        let prompt: String
        let trimmedMessages: [(role: String, content: String)]
    }

    /// Counts tokens on the assembled prompt and trims the oldest non-system
    /// messages until the prompt fits inside the context window.
    ///
    /// Up to `maxTrimAttempts` trimming rounds are performed. Each round drops
    /// one non-system message from the front of the history. If the budget is
    /// still exceeded after all attempts, throws
    /// ``InferenceError/contextExhausted(promptTokens:maxOutputTokens:contextSize:)``.
    private func exactPreflightAndTrim(
        counter: TokenCountingBackend,
        backend: InferenceBackend,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        config: GenerationConfig,
        maxTrimAttempts: Int = 20
    ) throws -> ExactPreflightResult {
        let contextSize = Int(backend.capabilities.maxContextTokens)
        // Reserve context for both visible output and (optionally) thinking output.
        //
        // Rationale for `?? 0` on the thinking side (not `?? 2048`): the public
        // semantics of `maxThinkingTokens` today are "cap reasoning output; nil
        // means no client-side cap." Reserving a fixed slice of the context
        // window for thinking by default would silently eat that many tokens
        // from every prompt — including on non-thinking models where it has no
        // effect on runtime behaviour. Principle of least surprise: only
        // reserve what the caller explicitly asked for. Callers who know they
        // are driving a reasoning model can opt in by setting
        // `maxThinkingTokens: N`, which then becomes the trim reservation.
        let visibleReserve = config.maxOutputTokens ?? 2048
        let thinkingReserve = config.maxThinkingTokens ?? 0
        let maxOutput = visibleReserve + thinkingReserve
        let template = provider?.selectedPromptTemplate ?? .chatML

        var workingMessages = messages
        var attempt = 0

        while true {
            let prompt = template.format(messages: workingMessages, systemPrompt: systemPrompt)
            let promptTokens = try counter.countTokens(prompt)

            if promptTokens + maxOutput <= contextSize {
                // Fits — return the (possibly trimmed) result.
                return ExactPreflightResult(prompt: prompt, trimmedMessages: workingMessages)
            }

            // Over budget. If we've used all trim rounds, surface the error before
            // anything reaches the C layer.
            guard attempt < maxTrimAttempts else {
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            // Find the oldest non-system message to drop. System messages are
            // passed in the `systemPrompt` parameter, not as tuples, so any
            // "system"-role tuple here is a slot injected by PromptAssembler.
            // We trim those too — keeping only the final user turn is better
            // than overflowing the KV cache.
            guard let dropIndex = workingMessages.firstIndex(where: { $0.role != "system" }) else {
                // Only system messages remain — nothing left to trim.
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            // Always protect the last user message: if dropping it would leave
            // no user turn, stop trimming and surface the error.
            let userCount = workingMessages.filter { $0.role == "user" }.count
            if userCount <= 1 && workingMessages[dropIndex].role == "user" {
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            Log.inference.warning(
                "GenerationCoordinator: prompt over budget — trimming oldest non-system message (attempt \(attempt + 1)/\(maxTrimAttempts))"
            )
            workingMessages.remove(at: dropIndex)
            attempt += 1
        }
    }

    // MARK: - Generation Queue

    func enqueue(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        maxToolIterations: Int = 10,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        guard provider?.currentBackend != nil, provider?.isBackendLoaded == true else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        guard requestQueue.count < maxQueueDepth else {
            throw InferenceError.inferenceFailure("Generation queue is full")
        }

        let token = GenerationRequestToken(rawValue: nextGenerationToken.rawValue + 1)
        nextGenerationToken = token

        var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation!
        let rawStream = AsyncThrowingStream<GenerationEvent, Error> { continuation = $0 }
        let stream = GenerationStream(rawStream)
        stream.setPhase(.queued)
        continuations[token] = continuation

        var config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens,
            tools: tools,
            toolChoice: toolChoice,
            jsonMode: jsonMode,
            maxToolIterations: maxToolIterations
        )
        config.maxThinkingTokens = maxThinkingTokens

        let request = QueuedRequest(
            token: token,
            priority: priority,
            sessionID: sessionID,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config,
            stream: stream
        )

        if let insertIdx = requestQueue.firstIndex(where: { $0.priority < priority }) {
            requestQueue.insert(request, at: insertIdx)
        } else {
            requestQueue.append(request)
        }

        drainQueue()
        return (token: token, stream: stream)
    }

    /// Processes the next queued request if no generation is active.
    private func drainQueue() {
        guard activeRequest == nil, !requestQueue.isEmpty else { return }

        let next = requestQueue.removeFirst()

        // Thermal gate: drop background requests under thermal pressure.
        if next.priority == .background {
            let thermal = thermalStateProvider()
            if thermal == .serious || thermal == .critical {
                let throttleError = InferenceError.inferenceFailure("Thermal throttle")
                Log.inference.warning("Dropping background generation \(next.token): thermal state \(thermal.rawValue)")
                next.stream.setPhase(.failed(throttleError.localizedDescription))
                finishAndDiscard(next.token, error: throttleError)
                drainQueue()
                return
            }
        }

        activeRequest = next
        isGenerating = true
        next.stream.setPhase(.connecting)

        activeTask = Task { [weak self] in
            guard let self else { return }

            var thrownError: Error?
            defer {
                if let continuation = self.continuations.removeValue(forKey: next.token) {
                    if let thrownError {
                        continuation.finish(throwing: thrownError)
                    } else {
                        continuation.finish()
                    }
                }
                if self.activeRequest?.token == next.token {
                    self.activeRequest = nil
                    self.activeTask = nil
                    self.isGenerating = false
                    self.drainQueue()
                }
            }

            do {
                try await self.runToolDispatchLoop(request: next)

                if Task.isCancelled {
                    next.stream.setPhase(.failed("Cancelled"))
                } else {
                    next.stream.setPhase(.done)
                }
            } catch {
                thrownError = error
                if Task.isCancelled {
                    next.stream.setPhase(.failed("Cancelled"))
                } else {
                    next.stream.setPhase(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Tool Dispatch Loop

    /// Upper bound on cumulative bytes of tool-result content that can be
    /// fed back into a single generation request.
    ///
    /// Tool results flow directly into the next-turn prompt, so a runaway
    /// tool (imagine one that mirrors an entire wiki article) can exhaust
    /// the KV cache on the server side just as surely as a misbehaving
    /// prompt. 512 KiB is deliberately generous for typical tool output
    /// (seconds-of-weather JSON, search snippets) but still well under the
    /// memory floor that would put an Ollama / local-llama deployment at
    /// risk. Overflow short-circuits the loop with a `.permanent`
    /// synthetic result rather than running another turn.
    private static let toolResultByteBudget: Int = 512 * 1024

    /// Drives the backend through an entire tool-dispatch loop for one
    /// queued request.
    ///
    /// On each iteration the backend is invoked with the current message
    /// history (original + any tool-call / tool-result entries accumulated
    /// from prior iterations). Events flow through to the request's
    /// continuation untouched *except* for `.toolCall(_:)` events, which
    /// are intercepted when a registry is present:
    ///
    /// 1. The call is dispatched via `toolRegistry.dispatch(_:)`.
    /// 2. A `.toolResult(_:)` event is emitted so UIs can render the
    ///    outcome alongside the call.
    /// 3. The `(call, result)` pair is appended to the tool-aware history
    ///    for the next iteration.
    ///
    /// Termination conditions:
    /// - The backend's stream finishes without emitting any new tool call
    ///   → normal completion.
    /// - `config.maxToolIterations` reached → emit `.toolLoopLimitReached`
    ///   and stop.
    /// - Cumulative tool-result bytes exceed ``toolResultByteBudget`` →
    ///   synthesise a `.permanent` error result and stop.
    /// - Backend emits an identical `(toolName, arguments)` pair twice in
    ///   a row → short-circuit the executor and feed a synthetic
    ///   "already-called-with-identical-args" result back so the model
    ///   can recover without another identical round trip.
    private func runToolDispatchLoop(request: QueuedRequest) async throws {
        // First-time-only wiring: make sure the registry has a schema
        // validator installed so tools with non-trivial parameter schemas
        // get argument validation without requiring the host to know about
        // the `JSONSchemaValidating` protocol.
        if let registry = toolRegistry, registry.validator == nil {
            registry.validator = JSONSchemaValidator()
        }

        let currentMessages = request.messages
        // `toolAwareHistory` is maintained in parallel for tool-call turns.
        // Seeded lazily on the first tool dispatch so plain-text turns keep
        // using the classic `setConversationHistory` path and existing
        // backends that don't know about tool-aware history see no change.
        var toolAwareHistory: [ToolAwareHistoryEntry]?
        var lastCallSignature: (toolName: String, arguments: String)?
        var toolResultByteTotal = 0
        var iterations = 0
        let limit = max(1, request.config.maxToolIterations)

        while true {
            iterations += 1
            if iterations > limit {
                // Cap reached — loop terminated before invoking the backend
                // with the next turn's request.
                Log.inference.warning(
                    "GenerationCoordinator: tool-dispatch loop hit maxToolIterations=\(limit, privacy: .public); terminating."
                )
                self.continuations[request.token]?.yield(
                    .toolLoopLimitReached(iterations: limit)
                )
                return
            }

            // Feed the tool-aware history to the backend when one is
            // available. Non-tool backends ignore the cast and fall back to
            // the plain conversation history via `generateWithConfig`.
            if let toolAwareHistory,
               let receiver = provider?.currentBackend as? ToolCallingHistoryReceiver {
                receiver.setToolAwareHistory(toolAwareHistory)
            }

            let stream = try self.generateWithConfig(
                messages: currentMessages,
                systemPrompt: request.systemPrompt,
                config: request.config
            )

            var dispatchedInThisTurn: [(ToolCall, ToolResult)] = []

            for try await event in stream.events {
                guard !Task.isCancelled else { return }

                if case .token = event, request.stream.phase != .streaming {
                    request.stream.setPhase(.streaming)
                }

                switch event {
                case .toolCall(let call) where toolRegistry != nil:
                    // Forward the call event so UI surfaces can render it
                    // alongside the pending result.
                    self.continuations[request.token]?.yield(.toolCall(call))

                    let result: ToolResult
                    if let prev = lastCallSignature,
                       prev.toolName == call.toolName,
                       prev.arguments == call.arguments {
                        // Identical repeat — don't re-invoke the executor.
                        Log.inference.warning(
                            "GenerationCoordinator: tool '\(call.toolName, privacy: .public)' called twice in a row with identical arguments; short-circuiting to previous result."
                        )
                        let prevContent = dispatchedInThisTurn.last?.1.content ?? ""
                        result = ToolResult(
                            callId: call.id,
                            content: "tool already called this turn with identical arguments — previous result was: \(prevContent)",
                            errorKind: .permanent
                        )
                    } else if toolResultByteTotal >= Self.toolResultByteBudget {
                        Log.inference.warning(
                            "GenerationCoordinator: tool-result byte budget (\(Self.toolResultByteBudget, privacy: .public)) exhausted before dispatching '\(call.toolName, privacy: .public)'; terminating loop."
                        )
                        result = ToolResult(
                            callId: call.id,
                            content: "tool result budget exhausted",
                            errorKind: .permanent
                        )
                    } else {
                        // User-approval gate: invoked on the finalized ToolCall,
                        // after the repeat / byte-budget guards (which both
                        // synthesize their own results without touching the
                        // registry). On `.denied` we emit a `.permissionDenied`
                        // ToolResult and continue the loop — the backend sees a
                        // structured refusal and the model usually apologises
                        // and asks what to do next.
                        switch await toolApprovalGate.approve(call) {
                        case .approved:
                            result = await toolRegistry!.dispatch(call)
                        case .denied(let reason):
                            Log.inference.info(
                                "GenerationCoordinator: tool '\(call.toolName, privacy: .public)' denied by ToolApprovalGate"
                            )
                            result = ToolResult(
                                callId: call.id,
                                content: reason ?? "user denied tool execution",
                                errorKind: .permissionDenied
                            )
                        }
                    }

                    toolResultByteTotal += result.content.utf8.count
                    lastCallSignature = (toolName: call.toolName, arguments: call.arguments)
                    dispatchedInThisTurn.append((call, result))

                    // Emit the result so the UI can render it; downstream
                    // consumers thread `.toolResult` into the current
                    // assistant bubble before the next turn begins.
                    self.continuations[request.token]?.yield(.toolResult(result))

                    // Overflow after this dispatch — synthesise a terminal
                    // marker and exit before running another turn.
                    if toolResultByteTotal >= Self.toolResultByteBudget {
                        return
                    }

                default:
                    self.continuations[request.token]?.yield(event)
                }
            }

            // If no tool calls were dispatched this turn, generation is
            // complete.
            if dispatchedInThisTurn.isEmpty {
                return
            }

            // Otherwise augment the tool-aware history with the tool-call +
            // tool-result pairs the model produced this turn, then loop.
            var nextHistory = toolAwareHistory ?? currentMessages.map {
                ToolAwareHistoryEntry(role: $0.role, content: $0.content)
            }
            nextHistory.append(
                ToolAwareHistoryEntry(
                    role: "assistant",
                    content: "",
                    toolCalls: dispatchedInThisTurn.map(\.0)
                )
            )
            for (call, result) in dispatchedInThisTurn {
                nextHistory.append(
                    ToolAwareHistoryEntry(
                        role: "tool",
                        content: result.content,
                        toolCallId: call.id
                    )
                )
            }
            toolAwareHistory = nextHistory
            // Keep `currentMessages` in sync so backends without
            // tool-aware support at least see the user-side history.
            // Tool/assistant-tool-call entries are omitted from the plain
            // path because `(role, content)` can't carry call ids faithfully.
        }
    }

    private func finishAndDiscard(_ token: GenerationRequestToken, error: Error? = nil) {
        if let error {
            continuations[token]?.finish(throwing: error)
        } else {
            continuations[token]?.finish(throwing: CancellationError())
        }
        continuations.removeValue(forKey: token)
    }

    func cancel(_ token: GenerationRequestToken) {
        if activeRequest?.token == token {
            provider?.currentBackend?.stopGeneration()
            activeTask?.cancel()
            activeTask = nil
            activeRequest?.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(token)
            activeRequest = nil
            isGenerating = false
            drainQueue()
        } else if let idx = requestQueue.firstIndex(where: { $0.token == token }) {
            let req = requestQueue.remove(at: idx)
            req.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(token)
        }
    }

    func discardRequests(notMatching sessionID: UUID) {
        requestQueue.removeAll { req in
            guard let reqSession = req.sessionID, reqSession != sessionID else { return false }
            req.stream.setPhase(.failed("Session changed"))
            finishAndDiscard(req.token, error: InferenceError.inferenceFailure("Session changed"))
            return true
        }
        if let active = activeRequest,
           let activeSession = active.sessionID,
           activeSession != sessionID {
            cancel(active.token)
        }
    }

    func stopGeneration() {
        provider?.currentBackend?.stopGeneration()
        activeTask?.cancel()
        activeTask = nil
        if let active = activeRequest {
            active.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(active.token, error: CancellationError())
        }
        activeRequest = nil
        isGenerating = false

        for req in requestQueue {
            req.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(req.token, error: CancellationError())
        }
        requestQueue.removeAll()
    }

    /// Cancels active generation and awaits the task's completion before returning.
    ///
    /// Captures the active task handle before calling `stopGeneration()` so the
    /// task's defer block fully completes before the caller proceeds.
    func stopGenerationAndWait() async {
        let task = activeTask
        stopGeneration()
        await task?.value
    }

}

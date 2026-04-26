import Foundation

// MARK: - ToolCallLoopPolicy

/// Bounds and heuristics that govern how a ``ToolCallLoopOrchestrator``
/// drives the generate → tool-call → execute → feed-result → generate loop.
///
/// Defaults err on the safe side for agent-style chat: a small step budget,
/// no wall-clock cap (callers wrap the whole stream in their own timeout if
/// they need one), and a 3-step identical-call window for cycle detection.
///
/// ## Example
/// ```swift
/// let policy = ToolCallLoopPolicy(
///     maxSteps: 6,
///     perStepTimeout: .seconds(30),
///     loopDetectionWindow: 3
/// )
/// let orchestrator = ToolCallLoopOrchestrator(
///     backend: backend,
///     executor: dispatcher,
///     policy: policy
/// )
/// ```
public struct ToolCallLoopPolicy: Sendable {

    /// Hard upper bound on `(generate, dispatch)` rounds in one ``ToolCallLoopOrchestrator/run(initialPrompt:systemPrompt:config:)``
    /// invocation. When the cap is hit the orchestrator emits
    /// ``ToolLoopEvent/stepLimitReached(steps:)`` and finishes.
    ///
    /// Defaults to `8`. Values `<= 0` are silently clamped to `1` — a zero
    /// budget would never let the loop start and is never the intent.
    public var maxSteps: Int

    /// Optional wall-clock cap applied to each `generate(...)` round.
    ///
    /// `nil` (default) disables the per-step timer. When set, the orchestrator
    /// races each backend call against `Task.sleep(for:)` and surfaces a
    /// ``ToolLoopError/stepTimedOut(step:)`` when the timer wins. Tool
    /// execution is *not* covered — executors enforce their own deadlines and
    /// surface ``ToolResult/ErrorKind/timeout`` directly.
    public var perStepTimeout: Duration?

    /// Number of trailing `(toolName, arguments)` pairs that must be identical
    /// for the loop-detection heuristic to fire.
    ///
    /// On a hit the orchestrator emits ``ToolLoopEvent/loopDetected(toolName:)``
    /// and finishes. Defaults to `3`. Values `<= 1` disable the heuristic
    /// entirely (a single tool call by itself is never a cycle).
    public var loopDetectionWindow: Int

    /// Creates a loop policy.
    ///
    /// - Parameters:
    ///   - maxSteps: Step budget. Clamped to `1...`. Defaults to `8`.
    ///   - perStepTimeout: Optional wall-clock cap per generate round. Defaults to `nil`.
    ///   - loopDetectionWindow: N identical consecutive `(name, args)` pairs that
    ///     trigger ``ToolLoopEvent/loopDetected(toolName:)``. Values `<= 1` disable
    ///     the heuristic. Defaults to `3`.
    public init(
        maxSteps: Int = 8,
        perStepTimeout: Duration? = nil,
        loopDetectionWindow: Int = 3
    ) {
        self.maxSteps = max(1, maxSteps)
        self.perStepTimeout = perStepTimeout
        self.loopDetectionWindow = loopDetectionWindow
    }
}

// MARK: - ToolLoopEvent

/// Events emitted by ``ToolCallLoopOrchestrator/run(initialPrompt:systemPrompt:config:)``.
///
/// Mirrors a subset of ``GenerationEvent`` plus three orchestrator-only
/// terminal events. Callers consume the stream until it finishes; the last
/// event is always one of ``finished``, ``stepLimitReached(steps:)`` or
/// ``loopDetected(toolName:)`` unless the stream throws.
public enum ToolLoopEvent: Sendable, Equatable {

    /// A fragment of visible text emitted by the model (forwarded verbatim
    /// from ``GenerationEvent/token(_:)``). Thinking-block tokens are not
    /// forwarded — agentic callers care about the visible output.
    case token(String)

    /// Streaming start of a tool call (forwarded verbatim from
    /// ``GenerationEvent/toolCallStart(callId:name:)``). Only emitted by
    /// backends whose
    /// ``BackendCapabilities/streamsToolCallArguments`` is `true`.
    case toolCallStart(callId: String, name: String)

    /// Streaming JSON-arguments fragment (forwarded verbatim from
    /// ``GenerationEvent/toolCallArgumentsDelta(callId:textDelta:)``). The
    /// authoritative arguments string lands on ``toolCall(_:)``.
    case toolCallArgumentsDelta(callId: String, textDelta: String)

    /// The model has requested a tool call. Emitted *before* dispatch so UIs
    /// can render the call in flight. The orchestrator dispatches the call
    /// itself; the host does not need to act.
    case toolCall(ToolCall)

    /// The result of a tool the orchestrator dispatched. Emitted *after*
    /// dispatch, before the next generate round. Forwards
    /// ``ToolResult/ErrorKind`` semantics unchanged from the executor.
    case toolResult(ToolResult)

    /// Token usage reported by the backend (cloud only today). Emitted as
    /// it arrives, possibly multiple times across the loop's rounds.
    case usage(prompt: Int, completion: Int)

    /// The policy step budget was hit before the model produced a non-tool
    /// turn. Terminal — no further events follow.
    case stepLimitReached(steps: Int)

    /// The cycle heuristic fired: the last
    /// ``ToolCallLoopPolicy/loopDetectionWindow`` `(toolName, arguments)`
    /// pairs were identical. Terminal — no further events follow.
    case loopDetected(toolName: String)

    /// The model produced a turn without emitting any tool call.
    /// Terminal — no further events follow.
    case finished
}

// MARK: - ToolLoopError

/// Errors thrown into the ``ToolCallLoopOrchestrator/run(initialPrompt:systemPrompt:config:)``
/// stream when the loop cannot continue.
public enum ToolLoopError: Error, Sendable, Equatable {

    /// A `generate(...)` round exceeded ``ToolCallLoopPolicy/perStepTimeout``.
    /// The associated value is the 1-indexed step number that timed out.
    case stepTimedOut(step: Int)
}

// MARK: - ToolCallLoopOrchestrator

/// Drives an agent-style generate → tool-call → execute → feed-result → generate
/// loop on top of a single ``InferenceBackend`` and a ``ToolExecutor`` (or a
/// ``ToolRegistry`` of executors).
///
/// The orchestrator is intentionally a separate, lower-level public API — it
/// does **not** replace ``InferenceService``. Use it when you want a thin
/// agentic harness without the queue, persistence, or
/// ``GenerationCoordinator`` plumbing.
///
/// ## Lifecycle
///
/// 1. Caller invokes ``run(initialPrompt:systemPrompt:config:)``.
/// 2. Orchestrator runs `backend.generate(...)`, forwarding ``GenerationEvent/token(_:)``,
///    ``GenerationEvent/usage(prompt:completion:)``, and ``GenerationEvent/toolCall(_:)``
///    events to the caller.
/// 3. On the *first* tool call in a round, the orchestrator collects all tool
///    calls emitted during that round, then dispatches each via the executor.
///    A ``ToolLoopEvent/toolResult(_:)`` is emitted per result.
/// 4. The result content is appended to the next prompt verbatim and a new
///    `generate(...)` round runs.
/// 5. When a round produces no tool calls, the orchestrator emits
///    ``ToolLoopEvent/finished``.
/// 6. If ``ToolCallLoopPolicy/maxSteps`` is exceeded, it emits
///    ``ToolLoopEvent/stepLimitReached(steps:)``.
/// 7. If the last ``ToolCallLoopPolicy/loopDetectionWindow`` `(name, args)`
///    pairs are identical, it emits ``ToolLoopEvent/loopDetected(toolName:)``.
///
/// ## Cancellation
///
/// Cancellation propagates through the consuming task — when the caller
/// cancels its iteration, the orchestrator's internal driver task observes
/// ``Swift/Task/isCancelled`` and calls ``InferenceBackend/stopGeneration()``
/// on the backend. No further events fire after cancellation.
///
/// ## Prompt formatting
///
/// The orchestrator concatenates tool results into the next prompt as
/// `"\n\nTool '<name>' result: <content>\n"` — the lowest-common-denominator
/// shape that drives the ``MockInferenceBackend`` test fixtures and works as a
/// portable default. Production callers that want richer formatting (e.g. a
/// proper `tool` role threaded through ``ToolCallingHistoryReceiver``) should
/// use ``GenerationCoordinator`` instead, which knows how to feed a structured
/// transcript back into backends that support it.
///
/// ## Multi-tool dispatch
///
/// The single-executor initializer covers the simple case of a single tool.
/// For multi-tool agents, prefer ``init(backend:registry:policy:)`` — the
/// orchestrator routes each call through ``ToolRegistry/dispatch(_:)`` which
/// looks up the right executor by name.
///
/// ## Parallel batch dispatch
///
/// When a single generation round emits more than one ``ToolCall``, the
/// orchestrator dispatches the batch in parallel via `withTaskGroup` only
/// when *every* executor in the batch returns
/// ``ToolExecutor/supportsConcurrentDispatch`` == `true`. Otherwise it falls
/// back to the sequential dispatch path that has always been the contract,
/// preserving ``ToolRegistry``'s reentrancy semantics for tools with shared
/// state.
///
/// Result order in the next-turn prompt is deterministic: results are sorted
/// by their batch-emission index before being appended, regardless of which
/// executor finishes first. KV-cache prefix reuse depends on stable
/// post-tool prompt prefixes, so this ordering is load-bearing.
///
/// Cancellation propagates through the task group: a cancelled consumer or
/// step-timeout drains in-flight executors and stops the backend without
/// emitting late ``ToolLoopEvent/toolResult(_:)`` events.
///
/// ## Example
/// ```swift
/// let orchestrator = ToolCallLoopOrchestrator(
///     backend: backend,
///     registry: registry,
///     policy: ToolCallLoopPolicy(maxSteps: 6)
/// )
/// for try await event in orchestrator.run(
///     initialPrompt: "What's the weather in Rome?",
///     systemPrompt: nil,
///     config: GenerationConfig()
/// ) {
///     switch event {
///     case .token(let t): print(t, terminator: "")
///     case .finished, .stepLimitReached, .loopDetected: break
///     default: break
///     }
/// }
/// ```
public struct ToolCallLoopOrchestrator: Sendable {

    private let backend: any InferenceBackend
    private let dispatcher: Dispatcher
    private let policy: ToolCallLoopPolicy

    /// Creates an orchestrator driven by a single ``ToolExecutor``.
    ///
    /// Every model-emitted ``ToolCall`` is routed to `executor` regardless of
    /// the call's ``ToolCall/toolName``. Use this initializer when you have
    /// exactly one tool, or when a host-built dispatcher already wraps a
    /// multi-tool registry behind a single executor surface.
    ///
    /// - Parameters:
    ///   - backend: The backend that produces tokens and tool calls.
    ///   - executor: Receives every dispatched call.
    ///   - policy: Loop bounds. Defaults to ``ToolCallLoopPolicy/init(maxSteps:perStepTimeout:loopDetectionWindow:)``.
    public init(
        backend: any InferenceBackend,
        executor: any ToolExecutor,
        policy: ToolCallLoopPolicy = .init()
    ) {
        self.backend = backend
        self.dispatcher = .singleExecutor(executor)
        self.policy = policy
    }

    /// Creates an orchestrator driven by a ``ToolRegistry``.
    ///
    /// Each ``ToolCall`` is dispatched through ``ToolRegistry/dispatch(_:)`` so
    /// the registry handles name lookup, JSON parsing, schema validation
    /// (when configured), and ``ToolResult/ErrorKind`` classification.
    ///
    /// - Parameters:
    ///   - backend: The backend that produces tokens and tool calls.
    ///   - registry: Multi-tool registry the orchestrator dispatches through.
    ///   - policy: Loop bounds. Defaults to ``ToolCallLoopPolicy/init(maxSteps:perStepTimeout:loopDetectionWindow:)``.
    public init(
        backend: any InferenceBackend,
        registry: ToolRegistry,
        policy: ToolCallLoopPolicy = .init()
    ) {
        self.backend = backend
        self.dispatcher = .registry(registry)
        self.policy = policy
    }

    // MARK: - run

    /// Streams the loop's events.
    ///
    /// The returned stream produces ``ToolLoopEvent`` values until the loop
    /// terminates with ``ToolLoopEvent/finished``,
    /// ``ToolLoopEvent/stepLimitReached(steps:)``, or
    /// ``ToolLoopEvent/loopDetected(toolName:)``. Errors thrown by the backend
    /// or by the per-step timeout are forwarded into the stream.
    ///
    /// Cancellation: when the consumer cancels its iteration, the orchestrator
    /// calls ``InferenceBackend/stopGeneration()`` on `backend` and finishes
    /// the stream without emitting further events.
    ///
    /// - Parameters:
    ///   - initialPrompt: First user-visible prompt.
    ///   - systemPrompt: Optional system prompt forwarded on every round.
    ///   - config: Sampling configuration. Forwarded verbatim each round —
    ///     callers that want a different `tools` list per round should construct
    ///     a fresh orchestrator.
    public func run(
        initialPrompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) -> AsyncThrowingStream<ToolLoopEvent, Error> {
        AsyncThrowingStream { continuation in
            let driver = Task {
                await self.drive(
                    initialPrompt: initialPrompt,
                    systemPrompt: systemPrompt,
                    config: config,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [backend] _ in
                driver.cancel()
                // The consumer dropped the stream (cancellation, break, or
                // natural finish). Telling the backend to stop here is a
                // best-effort no-op when generation has already completed
                // and a real cancel when it hasn't — matches the
                // InferenceBackend.stopGeneration() contract.
                backend.stopGeneration()
            }
        }
    }

    // MARK: - Driver

    private func drive(
        initialPrompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<ToolLoopEvent, Error>.Continuation
    ) async {
        var prompt = initialPrompt
        var step = 0
        var recentCalls: [CallSignature] = []

        while step < policy.maxSteps {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            step += 1

            let stream: GenerationStream
            do {
                stream = try backend.generate(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    config: config
                )
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let outcome: RoundOutcome
            do {
                outcome = try await consume(
                    stream: stream,
                    step: step,
                    continuation: continuation
                )
            } catch {
                continuation.finish(throwing: error)
                return
            }

            if outcome.cancelled {
                continuation.finish()
                return
            }

            if outcome.toolCalls.isEmpty {
                continuation.yield(.finished)
                continuation.finish()
                return
            }

            // Loop detection: track the last N (name, args) pairs across the
            // whole conversation. If the trailing window of `loopDetectionWindow`
            // pairs is identical, fire and finish.
            for call in outcome.toolCalls {
                recentCalls.append(CallSignature(name: call.toolName, arguments: call.arguments))
                if recentCalls.count > policy.loopDetectionWindow {
                    recentCalls.removeFirst(recentCalls.count - policy.loopDetectionWindow)
                }
                if policy.loopDetectionWindow > 1,
                   recentCalls.count == policy.loopDetectionWindow,
                   let first = recentCalls.first,
                   recentCalls.allSatisfy({ $0 == first }) {
                    continuation.yield(.loopDetected(toolName: first.name))
                    continuation.finish()
                    return
                }
            }

            // Dispatch the batch. Single-call rounds always go through the
            // sequential path (no behaviour change). Multi-call rounds opt
            // into `withTaskGroup` parallel dispatch only when every
            // executor in the batch returns
            // `ToolExecutor.supportsConcurrentDispatch == true`; otherwise
            // we fall back to sequential to preserve ToolRegistry's
            // reentrancy contract for tools with shared state.
            //
            // Result order in the next prompt is deterministic and matches
            // batch-emission order — KV-cache prefix reuse depends on a
            // stable post-tool prompt prefix.
            //
            // TODO(#753): MLX integration test for parallel multi-call output
            // — exercising tools with `supportsConcurrentDispatch == true`
            // against a real local model and asserting deterministic result
            // order.
            let results: [ToolResult]
            if outcome.toolCalls.count <= 1 {
                var sequential: [ToolResult] = []
                sequential.reserveCapacity(outcome.toolCalls.count)
                for call in outcome.toolCalls {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    let result = await dispatcher.dispatch(call)
                    continuation.yield(.toolResult(result))
                    sequential.append(result)
                }
                results = sequential
            } else if await dispatcher.canDispatchConcurrently(outcome.toolCalls) {
                let parallelOutcome = await dispatchParallel(
                    calls: outcome.toolCalls,
                    continuation: continuation
                )
                if parallelOutcome.cancelled {
                    continuation.finish()
                    return
                }
                results = parallelOutcome.results
            } else {
                var sequential: [ToolResult] = []
                sequential.reserveCapacity(outcome.toolCalls.count)
                for call in outcome.toolCalls {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    let result = await dispatcher.dispatch(call)
                    continuation.yield(.toolResult(result))
                    sequential.append(result)
                }
                results = sequential
            }

            var resultsAppendix = ""
            for (call, result) in zip(outcome.toolCalls, results) {
                resultsAppendix += "\n\nTool '\(call.toolName)' result: \(result.content)\n"
            }

            prompt = prompt + resultsAppendix
        }

        continuation.yield(.stepLimitReached(steps: step))
        continuation.finish()
    }

    // MARK: - Parallel dispatch

    private struct ParallelOutcome: Sendable {
        let results: [ToolResult]
        let cancelled: Bool
    }

    /// Dispatches `calls` concurrently via `withTaskGroup`, yields
    /// ``ToolLoopEvent/toolResult(_:)`` events sorted by batch index, and
    /// returns the results in batch-emission order.
    ///
    /// Determinism note: tasks complete in arbitrary order, but we collect
    /// `(idx, ToolResult)` pairs and sort by `idx` before yielding so the
    /// next-turn prompt prefix stays stable. KV-cache prefix reuse depends
    /// on this — see the type-level "Parallel batch dispatch" section.
    private func dispatchParallel(
        calls: [ToolCall],
        continuation: AsyncThrowingStream<ToolLoopEvent, Error>.Continuation
    ) async -> ParallelOutcome {
        let dispatcher = self.dispatcher
        let collected: [(Int, ToolResult)] = await withTaskGroup(
            of: (Int, ToolResult).self
        ) { group in
            defer { group.cancelAll() }
            for (idx, call) in calls.enumerated() {
                group.addTask {
                    let result = await dispatcher.dispatch(call)
                    return (idx, result)
                }
            }
            var out: [(Int, ToolResult)] = []
            out.reserveCapacity(calls.count)
            for await pair in group {
                out.append(pair)
            }
            return out
        }

        if Task.isCancelled {
            return ParallelOutcome(results: [], cancelled: true)
        }

        let sorted = collected.sorted { $0.0 < $1.0 }
        var results: [ToolResult] = []
        results.reserveCapacity(sorted.count)
        for (_, result) in sorted {
            continuation.yield(.toolResult(result))
            results.append(result)
        }
        return ParallelOutcome(results: results, cancelled: false)
    }

    /// Reads one round of events from the backend stream, optionally bounded
    /// by ``ToolCallLoopPolicy/perStepTimeout``. Forwards tokens, usage, and
    /// tool-call events as they arrive and returns the collected tool calls
    /// (empty when the round ended without one).
    private func consume(
        stream: GenerationStream,
        step: Int,
        continuation: AsyncThrowingStream<ToolLoopEvent, Error>.Continuation
    ) async throws -> RoundOutcome {
        if let timeout = policy.perStepTimeout {
            return try await withThrowingTaskGroup(of: RoundOutcome?.self) { group in
                let backend = self.backend
                group.addTask {
                    try await Self.consumeOnce(
                        stream: stream,
                        continuation: continuation
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    backend.stopGeneration()
                    throw ToolLoopError.stepTimedOut(step: step)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    return RoundOutcome(toolCalls: [], cancelled: true)
                }
                return first ?? RoundOutcome(toolCalls: [], cancelled: true)
            }
        } else {
            return try await Self.consumeOnce(stream: stream, continuation: continuation)
        }
    }

    private static func consumeOnce(
        stream: GenerationStream,
        continuation: AsyncThrowingStream<ToolLoopEvent, Error>.Continuation
    ) async throws -> RoundOutcome {
        var calls: [ToolCall] = []
        do {
            for try await event in stream.events {
                if Task.isCancelled {
                    return RoundOutcome(toolCalls: [], cancelled: true)
                }
                switch event {
                case .token(let text):
                    continuation.yield(.token(text))
                case .toolCallStart(let callId, let name):
                    continuation.yield(.toolCallStart(callId: callId, name: name))
                case .toolCallArgumentsDelta(let callId, let textDelta):
                    continuation.yield(.toolCallArgumentsDelta(callId: callId, textDelta: textDelta))
                case .toolCall(let call):
                    continuation.yield(.toolCall(call))
                    calls.append(call)
                case .usage(let p, let c):
                    continuation.yield(.usage(prompt: p, completion: c))
                case .thinkingToken, .thinkingComplete, .thinkingSignature,
                     .toolLoopLimitReached, .toolResult, .kvCacheReuse,
                     .diagnosticThrottle:
                    // Reasoning, KV-cache hints, and diagnostic events are
                    // not part of the orchestrator's surface. The legacy
                    // `.toolLoopLimitReached` / `.toolResult` events come
                    // from the in-service GenerationCoordinator path; this
                    // orchestrator emits its own equivalents.
                    continue
                }
            }
        } catch is CancellationError {
            return RoundOutcome(toolCalls: [], cancelled: true)
        }
        return RoundOutcome(toolCalls: calls, cancelled: false)
    }

    // MARK: - Internals

    private struct CallSignature: Equatable, Sendable {
        let name: String
        let arguments: String
    }

    private struct RoundOutcome: Sendable {
        let toolCalls: [ToolCall]
        let cancelled: Bool
    }

    /// Internal sum type so the orchestrator can take either a bare
    /// ``ToolExecutor`` (issue #443 spec) or a ``ToolRegistry`` (multi-tool
    /// reality) without exposing two separate run paths.
    private enum Dispatcher: Sendable {
        case singleExecutor(any ToolExecutor)
        case registry(ToolRegistry)

        func dispatch(_ call: ToolCall) async -> ToolResult {
            switch self {
            case .singleExecutor(let executor):
                return await Self.dispatchSingle(executor: executor, call: call)
            case .registry(let registry):
                return await registry.dispatch(call)
            }
        }

        /// Returns `true` when every executor that would handle one of
        /// `calls` has opted into concurrent dispatch.
        ///
        /// - Single-executor dispatcher: every call routes to the same
        ///   executor, so the answer is just that executor's flag.
        /// - Registry dispatcher: each call resolves to a (possibly
        ///   different) executor by name. The lookup is performed under
        ///   MainActor since ``ToolRegistry`` is MainActor-isolated.
        ///   Calls that resolve to no executor (unknown tool) are
        ///   considered non-concurrent — the dispatch will produce an
        ///   `unknownTool` error result and we don't want to short-circuit
        ///   that through a parallel path.
        func canDispatchConcurrently(_ calls: [ToolCall]) async -> Bool {
            switch self {
            case .singleExecutor(let executor):
                return executor.supportsConcurrentDispatch
            case .registry(let registry):
                return await MainActor.run {
                    for call in calls {
                        guard let executor = registry.executor(for: call.toolName) else {
                            return false
                        }
                        if !executor.supportsConcurrentDispatch {
                            return false
                        }
                    }
                    return true
                }
            }
        }

        private static func dispatchSingle(
            executor: any ToolExecutor,
            call: ToolCall
        ) async -> ToolResult {
            // Mirror the subset of ToolRegistry.dispatch's contract that
            // applies to a single executor: parse JSON arguments, invoke the
            // executor, classify thrown errors as `.permanent` (or `.cancelled`
            // when the surrounding task was cancelled), and stamp callId.
            let parsed: JSONSchemaValue
            if call.arguments.isEmpty {
                parsed = .object([:])
            } else if let data = call.arguments.data(using: .utf8) {
                do {
                    parsed = try JSONDecoder().decode(JSONSchemaValue.self, from: data)
                } catch {
                    return ToolResult(
                        callId: call.id,
                        content: "arguments are not valid JSON: \(error)",
                        errorKind: .invalidArguments
                    )
                }
            } else {
                return ToolResult(
                    callId: call.id,
                    content: "arguments are not valid JSON: non-UTF8 payload",
                    errorKind: .invalidArguments
                )
            }

            do {
                let raw = try await executor.execute(arguments: parsed)
                if Task.isCancelled {
                    return ToolResult(
                        callId: call.id,
                        content: "cancelled by user",
                        errorKind: .cancelled
                    )
                }
                return ToolResult(callId: call.id, content: raw.content, errorKind: raw.errorKind)
            } catch is CancellationError {
                return ToolResult(callId: call.id, content: "cancelled by user", errorKind: .cancelled)
            } catch {
                if Task.isCancelled {
                    return ToolResult(callId: call.id, content: "cancelled by user", errorKind: .cancelled)
                }
                return ToolResult(
                    callId: call.id,
                    content: String(describing: error),
                    errorKind: .permanent
                )
            }
        }
    }
}

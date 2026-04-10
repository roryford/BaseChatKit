import Foundation
import Observation

/// A factory closure that creates a local inference backend for the given model type.
/// Return `nil` if this factory does not handle the given type.
public typealias BackendFactory = @MainActor (ModelType) -> (any InferenceBackend)?

/// A factory closure that creates a cloud inference backend for the given API provider.
/// Return `nil` if this factory does not handle the given provider.
public typealias CloudBackendFactory = @MainActor (APIProvider) -> (any InferenceBackend)?

/// Orchestrates inference across multiple backends.
///
/// Selects the appropriate backend based on model format and delegates all
/// loading, generation, and lifecycle management to it. Views and view models
/// interact only with this service, never with backends directly.
///
/// Backends are pluggable via `registerBackendFactory` and
/// `registerCloudBackendFactory`. This keeps BaseChatCore free of any
/// direct dependency on MLX, llama.cpp, Foundation Models, or cloud SDKs —
/// those are registered by the app or the BaseChatBackends target at startup.
///
/// ## Load lifecycle guarantees
///
/// - **Latest-wins requests**: each `loadModel` / `loadCloudBackend` call creates
///   a new load request token; only the newest in-flight token may commit.
/// - **Stale completion suppression**: if an older request finishes after a newer
///   request started, stale successes are unloaded and stale failures are ignored
///   for state transitions.
/// - **Unload/preemption invalidation**: `unloadModel()` invalidates all
///   outstanding requests so late completions cannot restore a model.
///
/// These guarantees are service-level coordination semantics. Backend-specific
/// threading/execution constraints (for example MLX generation's main-thread
/// requirement) are unchanged.
///
/// ## Generation queue guarantees
///
/// - **Sequential FIFO**: only one backend `generate()` call is active at a time.
///   The queue is processed sequentially regardless of backend type.
/// - **Priority ordering**: `.userInitiated` > `.normal` > `.background`.
///   Within the same priority, requests execute in FIFO order.
/// - **Session scoping**: requests carry an optional session ID.
///   `discardRequests(notMatching:)` cancels all requests not belonging to the
///   specified session. Requests with `nil` sessionID are session-agnostic.
/// - **Per-request cancellation**: `cancel(_:)` removes a queued request or stops
///   the active one, then drains the next item.
/// - **Max queue depth**: excess `enqueue()` calls throw. Default: 8.
/// - **Thermal gating**: `.background` requests are dropped when the device is
///   under `.serious` or `.critical` thermal pressure.
/// - **`generationDidFinish()` contract**: callers MUST call this after consuming
///   the stream. Failure to do so stalls the queue permanently.
@Observable
@MainActor
public final class InferenceService {

    // MARK: - Published State

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    /// The name of the active backend (e.g., "MLX", "llama.cpp"), for display.
    public private(set) var activeBackendName: String?

    /// Progress of the in-flight model load, in `[0.0, 1.0]`.
    ///
    /// `nil` means no load is in progress. Set to `0.0` when `loadModel` or
    /// `loadCloudBackend` begins, then updated by backends that adopt
    /// ``LoadProgressReporting``. Backends without granular progress simply
    /// stay at `0.0` until ``isModelLoaded`` flips to `true`. Returns to `nil`
    /// once the load completes (success, failure, or supersession by a newer
    /// request).
    public private(set) var modelLoadProgress: Double?

    /// The prompt template to apply for backends that require one (GGUF).
    public var selectedPromptTemplate: PromptTemplate = .chatML

    // MARK: - Computed

    /// Capabilities of the currently loaded backend, or `nil` if none loaded.
    public var capabilities: BackendCapabilities? {
        backend?.capabilities
    }

    // MARK: - Memory Gate

    /// Optional pre-flight memory check. When set, `loadModel()` checks available
    /// memory before loading and either throws (iOS) or warns (macOS) if insufficient.
    public var memoryGate: MemoryGate?

    // MARK: - Backend Registry

    private var backendFactories: [BackendFactory] = []
    private var cloudBackendFactories: [CloudBackendFactory] = []

    /// Model types that have at least one registered factory.
    ///
    /// Populated by callers via `declareSupport(for:)` at registration time
    /// so the service can answer capability queries without instantiating backends.
    private var supportedLocalModelTypes: Set<ModelType> = []

    /// API providers that have at least one registered cloud factory.
    ///
    /// Cloud providers are always registered together by `DefaultBackends`, so
    /// callers declare the full set they support when they register factories.
    private var supportedCloudProviders: Set<APIProvider> = []

    /// Registers a factory that can create a local inference backend.
    ///
    /// Factories are tried in registration order; the first non-nil result wins.
    public func registerBackendFactory(_ factory: @escaping BackendFactory) {
        backendFactories.append(factory)
    }

    /// Registers a factory that can create a cloud inference backend.
    ///
    /// Factories are tried in registration order; the first non-nil result wins.
    public func registerCloudBackendFactory(_ factory: @escaping CloudBackendFactory) {
        cloudBackendFactories.append(factory)
    }

    /// Declares that a registered factory supports the given local model type.
    ///
    /// Call this immediately after `registerBackendFactory` for each model type
    /// the factory handles. `DefaultBackends.register(with:)` calls this automatically.
    public func declareSupport(for modelType: ModelType) {
        supportedLocalModelTypes.insert(modelType)
    }

    /// Declares that a registered factory supports the given API provider.
    ///
    /// Call this immediately after `registerCloudBackendFactory` for each provider
    /// the factory handles. `DefaultBackends.register(with:)` calls this automatically.
    public func declareSupport(for provider: APIProvider) {
        supportedCloudProviders.insert(provider)
    }

    // MARK: - Private State

    private var backend: (any InferenceBackend)?
    /// Monotonic identity for each load attempt.
    ///
    /// Invariants:
    /// - Tokens are strictly increasing for the lifetime of the service.
    /// - Only the latest requested token can commit a loaded backend.
    /// - `unloadModel()` invalidates all tokens issued up to that moment.
    private struct LoadRequestToken: Hashable, Comparable, Sendable {
        let rawValue: UInt64

        static let zero = Self(rawValue: 0)

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Generation Queue Types

    /// Monotonic identity for each generation request.
    public struct GenerationRequestToken: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let rawValue: UInt64
        static let zero = Self(rawValue: 0)
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        public var description: String { "gen-\(rawValue)" }
    }

    /// Priority for queued generation requests.
    /// Higher priority runs first; FIFO within the same level.
    public enum GenerationPriority: Int, Comparable, Sendable {
        case background = 0
        case normal = 1
        case userInitiated = 2
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct QueuedRequest {
        let token: GenerationRequestToken
        let priority: GenerationPriority
        let sessionID: UUID?
        let messages: [(role: String, content: String)]
        let systemPrompt: String?
        let config: GenerationConfig
        let stream: GenerationStream
    }

    // MARK: - Generation Queue State

    private var nextGenerationToken: GenerationRequestToken = .zero
    private var requestQueue: [QueuedRequest] = []
    private var activeRequest: QueuedRequest?
    private var activeTask: Task<Void, Never>?
    private var continuations: [GenerationRequestToken: AsyncThrowingStream<GenerationEvent, Error>.Continuation] = [:]

    /// Maximum queued requests. Excess enqueues fail immediately.
    private let maxQueueDepth = 8

    /// Whether there are pending requests behind the active one.
    public var hasQueuedRequests: Bool { !requestQueue.isEmpty }

    /// Tracks model-load lifecycle state.
    ///
    /// Invariants:
    /// - `.loading` and `.loaded` always reference a previously issued token.
    /// - `.loaded` means the loaded backend was committed by the same token.
    /// - Any completion that does not match the active `.loading` token is stale.
    private enum LoadPhase: Equatable {
        case idle
        case loading(request: LoadRequestToken)
        case loaded(request: LoadRequestToken)
    }

    private struct LoadRequestMetadata {
        let source: String
        let target: String
        let backend: String
        let startedAtUptime: TimeInterval
    }

    // Two-tier load coordination:
    // - InferenceService (this layer) owns backend state correctness via monotonic
    //   LoadRequestToken — stale successes are unloaded and stale failures are ignored.
    // - ChatViewModel owns UI task lifecycle via `latestLoadIntentGeneration` — it cancels
    //   superseded async tasks before they reach this layer.
    // Together they provide defense-in-depth: the VM avoids redundant load attempts;
    // this layer provides the hard correctness guarantee.
    private var nextLoadRequestToken: LoadRequestToken = .zero
    private var latestRequestedLoadToken: LoadRequestToken?
    private var invalidatedThroughToken: LoadRequestToken = .zero
    private var loadPhase: LoadPhase = .idle
    private var loadRequestMetadataByToken: [LoadRequestToken: LoadRequestMetadata] = [:]

    // MARK: - Model Lifecycle

    /// Loads a model using the appropriate backend for its format.
    ///
    /// If another load request starts before this call completes, this request is
    /// treated as stale and its completion is suppressed.
    public func loadModel(
        from modelInfo: ModelInfo,
        contextSize: Int32 = 2048
    ) async throws {
        unloadModel()

        guard let newBackend = createBackend(for: modelInfo.modelType) else {
            throw InferenceError.inferenceFailure(
                "No registered backend can handle model type \(modelInfo.modelType). "
                + "Register a BackendFactory before loading models."
            )
        }

        // Pre-flight memory check
        if let gate = memoryGate {
            let verdict = gate.check(
                modelFileSize: modelInfo.fileSize,
                strategy: newBackend.capabilities.memoryStrategy
            )
            switch verdict {
            case .allow:
                break
            case .warn(let estimated, let available):
                let estMB = estimated / 1_048_576
                let availMB = available / 1_048_576
                Log.inference.warning("Memory warning: model needs ~\(estMB) MB, \(availMB) MB available")
            case .deny(let estimated, let available):
                switch gate.denyBehavior {
                case .throwError:
                    throw InferenceError.memoryInsufficient(
                        required: estimated, available: available
                    )
                case .warnOnly:
                    let estMB = estimated / 1_048_576
                    let availMB = available / 1_048_576
                    Log.inference.warning("Memory insufficient: model needs ~\(estMB) MB, \(availMB) MB available. Proceeding (may swap).")
                }
            }
        }

        let backendName = backendDisplayName(for: modelInfo.modelType)
        let request = beginLoadRequest(
            source: "local",
            target: modelTypeLogLabel(modelInfo.modelType),
            backend: backendName
        )
        installProgressHandler(on: newBackend, for: request)
        do {
            // Run backend model loading off the main actor so heavy blocking work
            // (e.g. llama_model_load_from_file, llama_init_from_model) does not
            // freeze the UI or trigger the iOS watchdog gesture gate timeout.
            // After the Task completes we resume on @MainActor for the commit step.
            let url = modelInfo.url
            try await Task.detached(priority: .userInitiated) {
                try await newBackend.loadModel(from: url, contextSize: contextSize)
            }.value
        } catch {
            (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)
            let isStale = finishLoadAttemptWithFailure(request, error: error)
            if isStale {
                // The failure arrived after a newer request superseded this one.
                // Clean up any partial backend state so resources are not leaked.
                newBackend.unloadModel()
            }
            throw error
        }
        (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)

        logLoadEvent("load.complete", request: request)
        guard commitLoadIfCurrent(request: request, backend: newBackend, backendName: backendName) else {
            newBackend.unloadModel()
            logLoadEvent("load.suppress", request: request, reason: "stale-success", clearMetadata: true)
            return
        }
    }

    /// Loads a cloud API backend from an APIEndpoint configuration.
    ///
    /// Follows the same latest-wins/stale-suppression semantics as `loadModel`.
    public func loadCloudBackend(from endpoint: APIEndpoint) async throws {
        unloadModel()

        guard let url = URL(string: endpoint.baseURL) else {
            throw CloudBackendError.invalidURL(endpoint.baseURL)
        }

        guard let newBackend = createCloudBackend(for: endpoint.provider) else {
            throw InferenceError.inferenceFailure(
                "No registered cloud backend factory can handle provider \(endpoint.provider.rawValue). "
                + "Register a CloudBackendFactory before loading cloud backends."
            )
        }

        switch endpoint.provider {
        case .claude, .openAI, .custom:
            guard let keychainConfigurable = newBackend as? CloudBackendKeychainConfigurable else {
                throw InferenceError.inferenceFailure(
                    "Cloud backend \(type(of: newBackend)) must conform to CloudBackendKeychainConfigurable "
                    + "for provider \(endpoint.provider.rawValue)."
                )
            }
            keychainConfigurable.configure(
                baseURL: url,
                keychainAccount: endpoint.keychainAccount,
                modelName: endpoint.modelName
            )

        case .ollama, .lmStudio:
            guard let urlModelConfigurable = newBackend as? CloudBackendURLModelConfigurable else {
                throw InferenceError.inferenceFailure(
                    "Cloud backend \(type(of: newBackend)) must conform to CloudBackendURLModelConfigurable "
                    + "for provider \(endpoint.provider.rawValue)."
                )
            }
            urlModelConfigurable.configure(baseURL: url, modelName: endpoint.modelName)
        }

        let request = beginLoadRequest(
            source: "cloud",
            target: endpoint.provider.rawValue,
            backend: endpoint.provider.rawValue
        )
        installProgressHandler(on: newBackend, for: request)
        do {
            // Run backend initialisation off the main actor for consistency with
            // local model loading — cloud backends may perform blocking I/O during
            // their loadModel step (e.g. keychain reads, capability negotiation).
            let backendURL = url
            try await Task.detached(priority: .userInitiated) {
                try await newBackend.loadModel(from: backendURL, contextSize: 0)
            }.value
        } catch {
            (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)
            let isStale = finishLoadAttemptWithFailure(request, error: error)
            if isStale {
                // Clean up any partial backend state so resources are not leaked.
                newBackend.unloadModel()
            }
            throw error
        }
        (newBackend as? LoadProgressReporting)?.setLoadProgressHandler(nil)

        logLoadEvent("load.complete", request: request)
        guard commitLoadIfCurrent(
            request: request,
            backend: newBackend,
            backendName: endpoint.provider.rawValue
        ) else {
            newBackend.unloadModel()
            logLoadEvent("load.suppress", request: request, reason: "stale-success", clearMetadata: true)
            return
        }
    }

    /// Unloads the current model and frees all associated memory.
    ///
    /// Also preempts in-flight load requests by invalidating their request tokens.
    /// Any late completion from an invalidated request is discarded.
    public func unloadModel() {
        invalidateOutstandingLoads()
        stopGeneration()
        backend?.unloadModel()
        backend = nil
        isModelLoaded = false
        activeBackendName = nil
    }

    // MARK: - Generation

    /// Generates text from a message history, streaming tokens via the active backend.
    ///
    /// This is the low-level, non-queued entry point. It does **not** participate
    /// in the generation queue — use ``enqueue(messages:systemPrompt:temperature:topP:repeatPenalty:maxOutputTokens:priority:sessionID:)``
    /// for user-facing chat generation that must be serialized.
    ///
    /// Direct callers (title generation, compression) are short-lived and
    /// don't conflict with queued work because backends serialize at their own
    /// level (LlamaBackend via NSLock, MLXBackend via actor isolation).
    ///
    /// For backends that require prompt templates (GGUF), messages are formatted
    /// into a single prompt string using `selectedPromptTemplate`. For MLX and
    /// Foundation, the last user message is passed directly (they handle chat
    /// formatting internally).
    public func generate(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048
    ) throws -> GenerationStream {
        guard let backend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        let config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens
        )

        let prompt: String
        let effectiveSystemPrompt: String?

        if backend.capabilities.requiresPromptTemplate {
            // GGUF: format the entire conversation using the selected template.
            // System prompt is baked into the formatted string.
            prompt = selectedPromptTemplate.format(
                messages: messages,
                systemPrompt: systemPrompt
            )
            effectiveSystemPrompt = nil
        } else {
            // MLX / Foundation / Cloud: pass the last user message as prompt.
            // Cloud backends receive full history via their own mechanism.
            prompt = messages.last(where: { $0.role == "user" })?.content ?? ""
            effectiveSystemPrompt = systemPrompt
        }

        // For cloud backends, allow them to receive the full conversation history
        // via the ConversationHistoryReceiver protocol if they adopt it.
        if let historyReceiver = backend as? ConversationHistoryReceiver {
            historyReceiver.setConversationHistory(messages)
        }

        return try backend.generate(
            prompt: prompt,
            systemPrompt: effectiveSystemPrompt,
            config: config
        )
    }

    // MARK: - Generation Queue

    /// Enqueues a generation request and returns a token + stream pair.
    ///
    /// The stream starts in `.queued` phase and transitions to `.connecting`
    /// when the request reaches the front of the queue.
    public func enqueue(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        guard backend != nil, isModelLoaded else {
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

        let config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens
        )

        let request = QueuedRequest(
            token: token,
            priority: priority,
            sessionID: sessionID,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config,
            stream: stream
        )

        // Priority-sorted insertion: higher priority before lower, FIFO within same level.
        if let insertIdx = requestQueue.firstIndex(where: { $0.priority < priority }) {
            requestQueue.insert(request, at: insertIdx)
        } else {
            requestQueue.append(request)
        }

        drainQueue()
        return (token: token, stream: stream)
    }

    /// Processes the next queued request if no generation is active.
    ///
    /// Synchronous — launches a Task for the active generation, never awaits inline.
    /// This prevents actor reentrancy corruption.
    private func drainQueue() {
        guard activeRequest == nil, !requestQueue.isEmpty else { return }

        let next = requestQueue.removeFirst()

        // Thermal gate: drop background requests under thermal pressure.
        if next.priority == .background {
            let thermal = ProcessInfo.processInfo.thermalState
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

            // Ensure the continuation is always cleaned up, even if a new
            // cancellation or error path is added later. The nil-check is
            // intentional: cancel() may have already called finishAndDiscard().
            var thrownError: Error?
            defer {
                if let continuation = self.continuations.removeValue(forKey: next.token) {
                    if let thrownError {
                        continuation.finish(throwing: thrownError)
                    } else {
                        continuation.finish()
                    }
                }
            }

            do {
                let backendStream = try self.generate(
                    messages: next.messages,
                    systemPrompt: next.systemPrompt,
                    temperature: next.config.temperature,
                    topP: next.config.topP,
                    repeatPenalty: next.config.repeatPenalty,
                    maxOutputTokens: next.config.maxOutputTokens
                )

                for try await event in backendStream.events {
                    guard !Task.isCancelled else { break }
                    if case .token = event, next.stream.phase != .streaming {
                        next.stream.setPhase(.streaming)
                    }
                    self.continuations[next.token]?.yield(event)
                }

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
            // The consumer's defer block calls generationDidFinish(),
            // which clears activeRequest and triggers the next drain.
        }
    }

    /// Finishes the continuation for a token and removes it from the map.
    /// Every removal path must use this to prevent leaked continuations.
    private func finishAndDiscard(_ token: GenerationRequestToken, error: Error? = nil) {
        if let error {
            continuations[token]?.finish(throwing: error)
        } else {
            continuations[token]?.finish(throwing: CancellationError())
        }
        continuations.removeValue(forKey: token)
    }

    /// Cancels a specific generation request by token.
    ///
    /// If the token matches the active request, it is stopped and the next
    /// queued item begins. If queued, the request is removed without executing.
    public func cancel(_ token: GenerationRequestToken) {
        if activeRequest?.token == token {
            backend?.stopGeneration()
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

    /// Discards all queued and active requests that don't match the given session.
    ///
    /// Requests with `nil` sessionID are session-agnostic and are never discarded.
    public func discardRequests(notMatching sessionID: UUID) {
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

    /// Token usage from the last cloud API generation, if available.
    ///
    /// Backends that track token usage should adopt the `TokenUsageProvider` protocol.
    public var lastTokenUsage: (promptTokens: Int, completionTokens: Int)? {
        (backend as? TokenUsageProvider)?.lastUsage
    }

    /// Requests that the current generation stop and cancels all queued requests.
    public func stopGeneration() {
        backend?.stopGeneration()
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

    /// Notifies the service that generation has finished (called by view model
    /// after consuming the stream). Drains the next queued request if any.
    public func generationDidFinish() {
        activeRequest = nil
        activeTask = nil
        isGenerating = false
        drainQueue()
    }

    /// Resets conversation state in the active backend without unloading the model.
    ///
    /// Call when switching between sessions or stories so backends that track
    /// multi-turn history (e.g. Foundation) start fresh.
    public func resetConversation() {
        backend?.resetConversation()
    }

    // MARK: - Backend Selection

    private func createBackend(for modelType: ModelType) -> (any InferenceBackend)? {
        for factory in backendFactories {
            if let backend = factory(modelType) {
                return backend
            }
        }
        return nil
    }

    private func createCloudBackend(for provider: APIProvider) -> (any InferenceBackend)? {
        for factory in cloudBackendFactories {
            if let backend = factory(provider) {
                return backend
            }
        }
        return nil
    }

    private func backendDisplayName(for modelType: ModelType) -> String {
        switch modelType {
        case .mlx: "MLX"
        case .gguf: "llama.cpp"
        case .foundation: "Apple"
        }
    }

    private func beginLoadRequest(
        source: String,
        target: String,
        backend: String
    ) -> LoadRequestToken {
        let request = LoadRequestToken(rawValue: nextLoadRequestToken.rawValue + 1)
        nextLoadRequestToken = request
        latestRequestedLoadToken = request
        loadPhase = .loading(request: request)
        modelLoadProgress = 0.0
        loadRequestMetadataByToken[request] = LoadRequestMetadata(
            source: source,
            target: target,
            backend: backend,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        logLoadEvent("load.start", request: request)
        return request
    }

    /// Returns `true` if the failure was stale (superseded by a newer request).
    @discardableResult
    private func finishLoadAttemptWithFailure(_ request: LoadRequestToken, error: any Error) -> Bool {
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else {
            logLoadEvent("load.suppress", request: request, reason: "stale-failure", clearMetadata: true)
            return true
        }
        loadPhase = .idle
        modelLoadProgress = nil
        logLoadEvent(
            "load.failed",
            request: request,
            reason: String(reflecting: type(of: error)),
            clearMetadata: true
        )
        return false
    }

    private func invalidateOutstandingLoads() {
        if case .loading(let activeRequest) = loadPhase {
            logLoadEvent("load.cancel", request: activeRequest, reason: "unload")
        }
        if let latestRequestedLoadToken {
            invalidatedThroughToken = max(invalidatedThroughToken, latestRequestedLoadToken)
        }
        loadPhase = .idle
        modelLoadProgress = nil
    }

    private func canCommitLoad(_ request: LoadRequestToken) -> Bool {
        guard request > invalidatedThroughToken else {
            return false
        }
        guard latestRequestedLoadToken == request else {
            return false
        }
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else {
            return false
        }
        return true
    }

    @discardableResult
    private func commitLoadIfCurrent(
        request: LoadRequestToken,
        backend newBackend: any InferenceBackend,
        backendName: String
    ) -> Bool {
        guard canCommitLoad(request) else {
            return false
        }

        backend = newBackend
        isModelLoaded = true
        modelLoadProgress = nil
        activeBackendName = backendName
        loadPhase = .loaded(request: request)
        logLoadEvent("load.commit", request: request, clearMetadata: true)
        return true
    }

    /// Installs a stale-suppressing progress handler on the backend if it
    /// adopts ``LoadProgressReporting``. The handler hops to the main actor
    /// and only updates ``modelLoadProgress`` while `request` is still the
    /// active loading request.
    private func installProgressHandler(
        on newBackend: any InferenceBackend,
        for request: LoadRequestToken
    ) {
        guard let reporting = newBackend as? LoadProgressReporting else { return }
        reporting.setLoadProgressHandler { [weak self] progress in
            await MainActor.run { [weak self] in
                self?.applyLoadProgress(progress, for: request)
            }
        }
    }

    private func applyLoadProgress(_ progress: Double, for request: LoadRequestToken) {
        guard case .loading(let activeRequest) = loadPhase, activeRequest == request else {
            return
        }
        modelLoadProgress = max(0.0, min(1.0, progress))
    }

    private func modelTypeLogLabel(_ modelType: ModelType) -> String {
        switch modelType {
        case .mlx: "mlx"
        case .gguf: "gguf"
        case .foundation: "foundation"
        }
    }

    private func logLoadEvent(
        _ event: String,
        request: LoadRequestToken,
        reason: String? = nil,
        clearMetadata: Bool = false
    ) {
        let metadata = loadRequestMetadataByToken[request]
        let latencyMs = metadata.map {
            max(0, Int((ProcessInfo.processInfo.systemUptime - $0.startedAtUptime) * 1_000))
        }

        var message = "event=\(event) req=\(request.rawValue)"
        if let metadata {
            message += " source=\(metadata.source) target=\(metadata.target) backend=\(metadata.backend)"
        }
        if let latencyMs {
            message += " latency_ms=\(latencyMs)"
        }
        if let reason {
            message += " reason=\(reason)"
        }

        if event == "load.failed" {
            Log.inference.error("\(message, privacy: .public)")
        } else {
            Log.inference.info("\(message, privacy: .public)")
        }

        if clearMetadata {
            loadRequestMetadataByToken.removeValue(forKey: request)
        }
    }

    // MARK: - Initializers

    public nonisolated init() {}

    #if DEBUG
    /// Creates an InferenceService with a pre-loaded backend. For tests only.
    public init(backend: any InferenceBackend, name: String = "Mock") {
        self.backend = backend
        self.isModelLoaded = true
        self.activeBackendName = name
        let request = LoadRequestToken(rawValue: 1)
        self.nextLoadRequestToken = request
        self.latestRequestedLoadToken = request
        self.loadPhase = .loaded(request: request)
        // Populate metadata so unloadModel() log calls have context for this request.
        self.loadRequestMetadataByToken[request] = LoadRequestMetadata(
            source: "debug",
            target: name,
            backend: name,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
    }
    #endif

    // MARK: - Tokenizer

    /// A real tokenizer from the currently loaded backend, or `nil` if the active
    /// backend does not expose one (falls back to ``HeuristicTokenizer`` at call sites).
    ///
    /// Only backends that can tokenize synchronously vend a tokenizer here. Backends
    /// that require async tokenization (e.g. MLX via `ModelContainer.perform`) and
    /// backends with no tokenizer API (Foundation, cloud) return `nil`.
    public var tokenizer: (any TokenizerProvider)? {
        (backend as? TokenizerVendor)?.tokenizer
    }
}

// MARK: - Backend Snapshot

extension InferenceService {
    /// Returns a value snapshot of the currently declared-supported backends.
    ///
    /// Used by `FrameworkCapabilityService` to populate its `enabledBackends`
    /// property after backend registration completes.
    public func registeredBackendSnapshot() -> EnabledBackends {
        EnabledBackends(
            localModelTypes: supportedLocalModelTypes,
            cloudProviders: supportedCloudProviders
        )
    }
}

// MARK: - ModelTypeCompatibilityProvider Conformance

extension InferenceService: ModelTypeCompatibilityProvider {

    /// Returns whether a local model type has a registered backend in this service.
    public func compatibility(for modelType: ModelType) -> ModelCompatibilityResult {
        if supportedLocalModelTypes.contains(modelType) {
            return .supported
        }
        return .unsupported(reason: unavailableReasonString(for: modelType))
    }

    /// Returns whether a cloud API provider has a registered backend in this service.
    public func compatibility(for provider: APIProvider) -> ModelCompatibilityResult {
        if supportedCloudProviders.contains(provider) {
            return .supported
        }
        // Cloud backends are registered unconditionally when DefaultBackends is used,
        // so if a provider is missing it means no factory was registered at all.
        return .unsupported(reason: "No backend registered for \(provider.rawValue). Register a cloud backend factory at startup.")
    }

    // MARK: - Private helpers

    private func unavailableReasonString(for modelType: ModelType) -> String {
        switch modelType {
        case .gguf:
            return "GGUF models require the llama.cpp backend. Build with the Llama Swift package dependency to enable it."
        case .mlx:
            return "MLX models require Apple Silicon and the MLX backend. Build with the MLX Swift package dependency to enable it."
        case .foundation:
            return "Apple Foundation Models require iOS 26 / macOS 26 or later."
        }
    }
}

// MARK: - Supporting Protocols for Backend Opt-In Capabilities

/// Adopted by backends that can vend a synchronous ``TokenizerProvider``.
///
/// Use this when a backend has an efficient, thread-safe tokenizer available after
/// model load. Backends whose tokenizer requires `async` access should not conform.
public protocol TokenizerVendor: AnyObject {
    var tokenizer: any TokenizerProvider { get }
}

/// Adopted by cloud backends to receive the full conversation history for multi-turn support.
/// This avoids InferenceService having a hard dependency on specific backend types.
public protocol ConversationHistoryReceiver: AnyObject {
    func setConversationHistory(_ messages: [(role: String, content: String)])
}

/// Adopted by cloud backends that track token usage per response.
public protocol TokenUsageProvider: AnyObject {
    var lastUsage: (promptTokens: Int, completionTokens: Int)? { get }
}

/// Adopted by cloud backends configured with endpoint URL + model name.
public protocol CloudBackendURLModelConfigurable: AnyObject {
    func configure(baseURL: URL, modelName: String)
}

/// Adopted by cloud backends that resolve API keys via a Keychain account.
public protocol CloudBackendKeychainConfigurable: AnyObject {
    func configure(baseURL: URL, keychainAccount: String, modelName: String)
}

/// Adopted by backends that can report granular model-load progress.
///
/// `InferenceService` installs a handler before each load and clears it
/// (`nil`) once the load has completed or failed. Handlers may be invoked
/// from any thread; the closure is `@Sendable`. Backends without granular
/// progress need not adopt this protocol — `InferenceService` will simply
/// publish `0.0` until `isModelLoaded` flips to `true`.
public protocol LoadProgressReporting: AnyObject {
    /// Installs (or clears, when `nil`) a progress callback for the next
    /// `loadModel` call. Values must be in `[0.0, 1.0]`. Implementations
    /// should retain the handler only for the duration of the active load.
    func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?)
}

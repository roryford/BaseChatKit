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
/// - **Auto-drain**: the queue drains automatically when each stream terminates.
///   `generationDidFinish()` is deprecated and is now a no-op.
@Observable
@MainActor
public final class InferenceService {

    // MARK: - Internal Coordinators

    private let lifecycle: ModelLifecycleCoordinator
    private let generation: GenerationCoordinator

    // MARK: - Public Type Aliases (preserve InferenceService.GenerationRequestToken syntax)

    public typealias GenerationRequestToken = BaseChatInference.GenerationRequestToken
    public typealias GenerationPriority = BaseChatInference.GenerationPriority

    // MARK: - Published State (forwarded from coordinators)

    public var isModelLoaded: Bool { lifecycle.isModelLoaded }
    public var isGenerating: Bool { generation.isGenerating }
    public var activeBackendName: String? { lifecycle.activeBackendName }
    public var modelLoadProgress: Double? { lifecycle.modelLoadProgress }

    /// The prompt template to apply for backends that require one (GGUF).
    public var selectedPromptTemplate: PromptTemplate {
        get { lifecycle.selectedPromptTemplate }
        set { lifecycle.selectedPromptTemplate = newValue }
    }

    // MARK: - Computed

    public var capabilities: BackendCapabilities? { lifecycle.capabilities }

    // MARK: - Deny Policy

    /// Policy applied when a ``ModelLoadPlan`` returns a ``ModelLoadPlan/Verdict/deny``
    /// verdict. Defaults to ``LoadDenyPolicy/platformDefault`` (iOS: `.throwError`,
    /// macOS: `.warnOnly`). Custom hooks receive the full plan so they can inspect
    /// `reasons` before deciding whether to proceed.
    public var denyPolicy: LoadDenyPolicy = .platformDefault {
        didSet { lifecycle.denyPolicy = denyPolicy }
    }

    // MARK: - Backend Registration

    public func registerBackendFactory(_ factory: @escaping BackendFactory) {
        lifecycle.registerBackendFactory(factory)
    }

    public func registerCloudBackendFactory(_ factory: @escaping CloudBackendFactory) {
        lifecycle.registerCloudBackendFactory(factory)
    }

    public func declareSupport(for modelType: ModelType) {
        lifecycle.declareSupport(for: modelType)
    }

    public func declareSupport(for provider: APIProvider) {
        lifecycle.declareSupport(for: provider)
    }

    // MARK: - Model Lifecycle

    /// Loads a model using the appropriate backend for its format.
    ///
    /// If another load request starts before this call completes, this request is
    /// treated as stale and its completion is suppressed.
    @available(*, deprecated, message: "Use loadModel(from:plan:); build the plan with ModelLoadPlan.compute(for:requestedContextSize:strategy:)")
    public func loadModel(
        from modelInfo: ModelInfo,
        contextSize: Int32 = 2048
    ) async throws {
        ensureProviderWired()
        generation.stopGeneration()
        // Delegation without a plan: the coordinator picks the backend first and
        // then builds a plan using the backend's declared memory strategy. This
        // preserves the legacy behaviour where `MemoryStrategy` was sourced from
        // `backend.capabilities.memoryStrategy`.
        try await lifecycle.loadModel(from: modelInfo, contextSize: contextSize)
    }

    /// Loads a model using a precomputed ``ModelLoadPlan``.
    ///
    /// Prefer this over ``loadModel(from:contextSize:)`` when the caller has already
    /// produced a plan (for example via the UI load flow). The plan carries the
    /// authoritative effective context size and memory verdict.
    public func loadModel(
        from modelInfo: ModelInfo,
        plan: ModelLoadPlan
    ) async throws {
        ensureProviderWired()
        generation.stopGeneration()
        try await lifecycle.loadModel(from: modelInfo, plan: plan)
    }

    /// Loads a cloud API backend from an `APIEndpointRecord` configuration.
    ///
    /// Follows the same latest-wins/stale-suppression semantics as `loadModel`.
    public func loadCloudBackend(from endpoint: APIEndpointRecord) async throws {
        ensureProviderWired()
        generation.stopGeneration()
        try await lifecycle.loadCloudBackend(from: endpoint)
    }

    /// Unloads the current model and frees all associated memory.
    ///
    /// Also cancels in-flight generation and preempts outstanding load requests.
    public func unloadModel() {
        ensureProviderWired()
        generation.stopGeneration()
        lifecycle.unloadModel()
    }

    // MARK: - Generation

    /// Generates text from a message history, streaming tokens via the active backend.
    ///
    /// This is the low-level, non-queued entry point. Use ``enqueue`` for
    /// user-facing chat generation that must be serialized.
    public func generate(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048
    ) throws -> GenerationStream {
        ensureProviderWired()
        return try generation.generate(
            messages: messages,
            systemPrompt: systemPrompt,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens
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
        ensureProviderWired()
        return try generation.enqueue(
            messages: messages,
            systemPrompt: systemPrompt,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens,
            priority: priority,
            sessionID: sessionID
        )
    }

    /// Cancels a specific generation request by token.
    ///
    /// If the token matches the active request, it is stopped and the next
    /// queued item begins. If queued, the request is removed without executing.
    public func cancel(_ token: GenerationRequestToken) {
        ensureProviderWired()
        generation.cancel(token)
    }

    public func discardRequests(notMatching sessionID: UUID) {
        ensureProviderWired()
        generation.discardRequests(notMatching: sessionID)
    }

    public var lastTokenUsage: (promptTokens: Int, completionTokens: Int)? {
        ensureProviderWired()
        return generation.lastTokenUsage
    }

    /// Requests that the current generation stop and cancels all queued requests.
    public func stopGeneration() {
        ensureProviderWired()
        generation.stopGeneration()
    }

    public var hasQueuedRequests: Bool {
        ensureProviderWired()
        return generation.hasQueuedRequests
    }

    @available(*, deprecated, message: "The queue auto-drains when the stream terminates. This method is a no-op and will be removed in a future release.")
    public func generationDidFinish() {}

    public func resetConversation() {
        lifecycle.resetConversation()
    }

    // MARK: - Tokenizer

    public var tokenizer: (any TokenizerProvider)? {
        lifecycle.tokenizer
    }

    // MARK: - Initializers

    public nonisolated init() {
        self.lifecycle = ModelLifecycleCoordinator()
        self.generation = GenerationCoordinator()
        // Provider wiring happens lazily via ensureProviderWired() on first use,
        // since `self` is not available inside a nonisolated init.
    }

    #if DEBUG
    public init(backend: any InferenceBackend, name: String = "Mock") {
        self.lifecycle = ModelLifecycleCoordinator(backend: backend, name: name)
        self.generation = GenerationCoordinator()
        generation.provider = self
    }
    #endif

    /// Ensures the generation coordinator has a reference to this service.
    ///
    /// Called lazily because `nonisolated init()` cannot access `self` as a
    /// `@MainActor`-isolated reference. All public entry points that touch the
    /// generation coordinator call this first.
    private func ensureProviderWired() {
        if generation.provider == nil {
            generation.provider = self
        }
    }
}

// MARK: - GenerationContextProvider Conformance

extension InferenceService: GenerationContextProvider {
    public var currentBackend: (any InferenceBackend)? { lifecycle.backend }
    public var isBackendLoaded: Bool { lifecycle.isModelLoaded }
}

// MARK: - Backend Snapshot

extension InferenceService {
    public func registeredBackendSnapshot() -> EnabledBackends {
        lifecycle.registeredBackendSnapshot()
    }
}

// MARK: - ModelTypeCompatibilityProvider Conformance

extension InferenceService: ModelTypeCompatibilityProvider {

    public func compatibility(for modelType: ModelType) -> ModelCompatibilityResult {
        lifecycle.compatibility(for: modelType)
    }

    public func compatibility(for provider: APIProvider) -> ModelCompatibilityResult {
        lifecycle.compatibility(for: provider)
    }
}

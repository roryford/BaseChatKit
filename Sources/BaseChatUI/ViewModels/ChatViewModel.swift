import Foundation
import Observation
import BaseChatCore
import BaseChatInference

/// Central view model for the chat interface.
///
/// Manages the message history, model lifecycle, generation settings, context
/// tracking, export, and SwiftData persistence. Views observe this via
/// `@Environment` and never call services directly.
///
/// ## Sharing InferenceService across components
///
/// `inferenceService` is intentionally `internal` — downstream apps should
/// create the service at the app level and inject it into all consumers:
///
/// ```swift
/// let inference = InferenceService()
/// let chatVM = ChatViewModel(inferenceService: inference)
/// let storyStore = StoryStore(inferenceService: inference)
/// ```
///
/// This keeps ChatViewModel's load coordination and state machine consistent.
/// Do not expose `inferenceService` publicly; if new consumers need generation
/// without lifecycle control, extract a focused protocol instead.
@Observable
@MainActor
public final class ChatViewModel {

    // MARK: - Services

    let inferenceService: InferenceService
    let deviceCapability: DeviceCapabilityService
    let modelStorage: ModelStorageService
    let memoryPressure: MemoryPressureHandler

    // MARK: - Persistence

    let sessionController: SessionController

    var persistence: ChatPersistenceProvider? {
        get { sessionController.persistence }
        set { sessionController.persistence = newValue }
    }

    // MARK: - Session

    /// The currently active chat session. Set via `switchToSession(_:)`.
    public var activeSession: ChatSessionRecord? {
        get { sessionController.activeSession }
        set { sessionController.activeSession = newValue }
    }

    /// The session ID for the active session, or `nil` if no session is selected.
    var activeSessionID: UUID? { sessionController.activeSessionID }

    /// Called when a session might need its title auto-generated.
    /// Set by the view layer to connect to SessionManagerViewModel.
    public var onFirstMessage: (@MainActor (ChatSessionRecord, String) -> Void)?

    // MARK: - First Run / Onboarding

    /// Called on the first launch instead of the default first-run behaviour.
    ///
    /// When set, this closure is invoked by `autoSelectFirstRunModel()` and the default
    /// Foundation model auto-selection is skipped entirely. If `nil`, the default
    /// behaviour auto-selects the Foundation model (if available); the model load itself
    /// is deferred to the view's `onChange(of: selectedModel)` handler to avoid a
    /// double-load race condition.
    public var onFirstLaunch: (@MainActor () -> Void)?

    /// Returns `true` if the Foundation model backend is available on this device.
    /// Apps should set this to enable Foundation model auto-discovery.
    /// Example: `chatViewModel.foundationModelProvider = { FoundationBackend.isAvailable }`
    public var foundationModelProvider: (@MainActor () -> Bool)?

    // MARK: - Published State

    /// All models discovered on disk plus the built-in Foundation model.
    public internal(set) var availableModels: [ModelInfo] = []

    /// Enabled cloud endpoints available for selection.
    public internal(set) var availableEndpoints: [APIEndpoint] = []

    /// The model the user has selected in the sidebar.
    public var selectedModel: ModelInfo? {
        didSet {
            guard !isSynchronizingSelection else { return }
            guard selectedModel != nil, selectedEndpoint != nil else { return }
            isSynchronizingSelection = true
            selectedEndpoint = nil
            isSynchronizingSelection = false
        }
    }

    /// The cloud API endpoint the user has selected, or `nil` for local models.
    /// Setting this clears `selectedModel` and vice versa.
    public var selectedEndpoint: APIEndpoint? {
        didSet {
            guard !isSynchronizingSelection else { return }
            guard selectedEndpoint != nil, selectedModel != nil else { return }
            isSynchronizingSelection = true
            selectedModel = nil
            isSynchronizingSelection = false
        }
    }

    /// Ordered messages for the active session.
    public internal(set) var messages: [ChatMessageRecord] {
        get { sessionController.messages }
        set { sessionController.messages = newValue }
    }

    /// The user's current input text.
    public var inputText: String = ""

    /// Editable system prompt prepended to every generation.
    public var systemPrompt: String {
        get { sessionController.systemPrompt }
        set { sessionController.systemPrompt = newValue }
    }

    /// The current phase of backend activity, driving all status indicators.
    ///
    /// The setter is `internal(set)` for SwiftUI observation, but all production
    /// code paths must mutate this via ``transitionPhase(to:)`` so the
    /// ``ActivityPhaseStateMachine`` can validate the transition. Test-only
    /// direct writes bypass validation — see the state machine tests for
    /// exhaustive legal-transition coverage.
    public internal(set) var activityPhase: BackendActivityPhase = .idle {
        didSet {
            phaseMachine = ActivityPhaseStateMachine(phase: activityPhase)
            let wasGenerating = oldValue == .waitingForFirstToken || oldValue == .streaming
            let nowGenerating = activityPhase == .waitingForFirstToken || activityPhase == .streaming
            if wasGenerating != nowGenerating {
                onGeneratingChanged?(nowGenerating)
            }
            onActivityPhaseChanged?(activityPhase)
        }
    }

    /// Single source of truth for legal phase transitions. The view model
    /// never mutates `activityPhase` directly — every production code path
    /// routes through ``transitionPhase(to:)``.
    @ObservationIgnored
    private var phaseMachine = ActivityPhaseStateMachine(phase: .idle)

    /// Attempt to move to `newPhase`. Illegal transitions are logged and
    /// dropped — callers that know they may lose a race (stale progress
    /// callbacks, late stall notifications) rely on this to be a no-op.
    ///
    /// Returns `true` if the phase actually changed, `false` if the
    /// transition was rejected or was a same-phase no-op.
    @discardableResult
    func transitionPhase(to newPhase: BackendActivityPhase) -> Bool {
        let result = phaseMachine.transition(to: newPhase)
        switch result {
        case .applied:
            activityPhase = phaseMachine.phase
            return true
        case .unchanged:
            return false
        case .rejected(let from, let to):
            // Rejected transitions are a defence against bugs *and* a
            // defence against stale async events. We log at warning level
            // so CI surfaces unexpected bugs without crashing tests in
            // debug — per CLAUDE.md, `assertionFailure` is reserved for
            // conditions with no recovery path, and every rejection here
            // has an implicit recovery (ignore the event).
            Log.ui.warning(
                "ActivityPhaseStateMachine rejected transition: \(String(describing: from)) → \(String(describing: to))"
            )
            return false
        }
    }

    /// Whether a model is currently being loaded. Derived from `activityPhase`.
    public var isLoading: Bool {
        if case .modelLoading = activityPhase { return true }
        return false
    }

    /// Whether inference is currently streaming tokens. Derived from `activityPhase`.
    public var isGenerating: Bool {
        activityPhase == .waitingForFirstToken || activityPhase == .streaming
    }

    /// Test-only hook invoked whenever `isGenerating` changes.
    var onGeneratingChanged: ((Bool) -> Void)?

    /// Test-only hook invoked whenever `activityPhase` changes.
    var onActivityPhaseChanged: ((BackendActivityPhase) -> Void)?

    /// Structured error with recovery information for the UI.
    public var activeError: ChatError?

    /// Backward-compatible string accessor for error display.
    /// Returns the message from the active error, or nil if no error.
    public var errorMessage: String? {
        get { activeError?.message }
        set {
            if let message = newValue {
                activeError = ChatError(kind: .configuration, message: message, recovery: .dismissOnly)
            } else {
                activeError = nil
            }
        }
    }

    // MARK: - Post-Generation Tasks

    /// Background tasks to run after each generation completes, in registration order.
    ///
    /// Tasks run sequentially off `@MainActor`. A task that throws surfaces its
    /// error in ``backgroundTaskError`` but does not cancel subsequent tasks.
    /// All tasks are cancelled when the session is reset via ``switchToSession(_:)``.
    public var postGenerationTasks: [any PostGenerationTask] = []

    /// The most recent non-fatal error thrown by a post-generation background task.
    ///
    /// Surfaced for optional display by the app. Does not interrupt the session.
    public internal(set) var backgroundTaskError: Error?

    // MARK: - Pinned Messages

    /// IDs of messages that are pinned in the current session.
    ///
    /// Populated from ``ChatSessionRecord/pinnedMessageIDs`` when switching
    /// sessions. Persisted back to the session on changes.
    public internal(set) var pinnedMessageIDs: Set<UUID> {
        get { sessionController.pinnedMessageIDs }
        set { sessionController.pinnedMessageIDs = newValue }
    }

    // MARK: - Generation Settings

    public var temperature: Float {
        get { sessionController.temperature }
        set { sessionController.temperature = newValue }
    }
    public var topP: Float {
        get { sessionController.topP }
        set { sessionController.topP = newValue }
    }
    public var repeatPenalty: Float {
        get { sessionController.repeatPenalty }
        set { sessionController.repeatPenalty = newValue }
    }
    /// Minimum interval between batched UI updates during streaming (~30 fps by default).
    public var streamingUpdateInterval: Duration = .milliseconds(33)
    /// Maximum characters to buffer before forcing a UI flush during streaming.
    public var streamingBatchCharacterLimit: Int = 128

    /// Whether to automatically stop generation when repetitive looping is detected.
    /// Defaults to `true`. Disable for apps that handle loop detection themselves.
    public var loopDetectionEnabled: Bool = true

    /// Simple key/value substitution for system prompt templates.
    ///
    /// Tokens written as `{{key}}` in the system prompt are replaced with the
    /// corresponding value in a single regex pass before the prompt reaches
    /// the backend. Intended for apps that want to inject a few strings (user
    /// name, persona, etc.) into a template without writing their own
    /// expansion layer.
    ///
    /// Behavior:
    /// - **Missing keys pass through.** A token whose key is not in the dict
    ///   is left in the prompt verbatim (e.g. `{{missing}}`), so callers can
    ///   spot typos by eye.
    /// - **All occurrences replaced.** Every occurrence of `{{key}}` in the
    ///   prompt is replaced, not just the first.
    /// - **Non-recursive.** If a value contains its own `{{token}}` pattern,
    ///   that nested token is left literal rather than re-substituted. E.g.,
    ///   setting `systemPromptContext["foo"] = "{{bar}}"` results in
    ///   `{{foo}}` expanding to the literal string `{{bar}}`, not recursively
    ///   into `{{bar}}`'s value. The single-pass scan also makes the result
    ///   independent of dictionary iteration order.
    /// - **Token pattern is `{{\w+}}`** — only alphanumeric and underscore
    ///   characters are recognized inside the braces. Anything else (spaces,
    ///   dots, empty `{{}}`) is ignored and passes through as literal text.
    public var systemPromptContext: [String: String] = [:]

    /// Prompt template for GGUF backends. Ignored by MLX/Foundation.
    public var selectedPromptTemplate: PromptTemplate {
        get { sessionController.selectedPromptTemplate }
        set {
            sessionController.selectedPromptTemplate = newValue
            inferenceService.selectedPromptTemplate = newValue
        }
    }

    // MARK: - Context Tracking

    /// Estimated tokens used by current messages + system prompt.
    public internal(set) var contextUsedTokens: Int = 0

    /// Maximum tokens for the current model/session configuration.
    public internal(set) var contextMaxTokens: Int = 2048

    /// Ratio of context used (0.0 to 1.0+).
    public var contextUsageRatio: Double {
        guard contextMaxTokens > 0 else { return 0 }
        return Double(contextUsedTokens) / Double(contextMaxTokens)
    }

    // MARK: - Computed Properties

    public var isModelLoaded: Bool {
        inferenceService.isModelLoaded
    }

    public var deviceDescription: String {
        deviceCapability.deviceDescription
    }

    public var recommendedSize: ModelSizeRecommendation {
        deviceCapability.recommendedModelSize()
    }

    public var modelsDirectoryPath: String {
        modelStorage.modelsDirectory.path
    }

    /// Capabilities of the active backend, or `nil` if none loaded.
    public var backendCapabilities: BackendCapabilities? {
        inferenceService.capabilities
    }

    public var activeBackendName: String? {
        inferenceService.activeBackendName
    }

    // MARK: - Onboarding

    /// `true` on the very first launch (before first-run logic runs).
    public internal(set) var isFirstRun: Bool

    /// Set to `true` after the first Foundation-backed assistant response completes
    /// in a session, suggesting the user download a local model for longer context.
    /// Apps can override this behaviour by replacing `onUpgradeHintTriggered`.
    public internal(set) var showUpgradeHint: Bool = false

    /// Called when the upgrade hint is first shown. Override to customise behaviour.
    /// Default is `nil` (no-op — the hint banner is displayed by `ChatView`).
    public var onUpgradeHintTriggered: (@MainActor () -> Void)?

    // MARK: - Memory Indicator

    /// The current OS-level memory pressure level, forwarded from the handler.
    public var memoryPressureLevel: MemoryPressureLevel {
        memoryPressure.pressureLevel
    }

    /// Physical RAM of this device in bytes.
    public var physicalMemoryBytes: UInt64 {
        deviceCapability.physicalMemory
    }

    /// Current resident memory used by this process in bytes, sampled via Mach task info.
    ///
    /// Returns `nil` if the kernel call fails (should not happen in practice).
    public var appMemoryUsageBytes: UInt64? {
        AppMemoryUsage.currentBytes()
    }

    // MARK: - Private State

    enum LoadIntent {
        case localModel(ModelInfo)
        case cloudEndpoint(APIEndpoint)
    }

    /// Token for the currently active generation request, if any.
    var activeGenerationToken: InferenceService.GenerationRequestToken?
    var generationTask: Task<Void, Never>?
    var backgroundTask: Task<Void, Never>?
    var coordinatedLoadTask: Task<Void, Never>?
    var latestLoadIntentGeneration: UInt64 = 0

    /// Polling interval for the model-load progress bridge task that mirrors
    /// `inferenceService.modelLoadProgress` into ``activityPhase``. Tests may
    /// override this to a small value for deterministic timing.
    var progressBridgePollInterval: Duration = .milliseconds(50)

    /// Minimum interval between published phase transitions for in-flight
    /// model-load progress. Keeps steadily-progressing backends from
    /// re-rendering every view observing ``activityPhase`` on every poll tick.
    /// The first emission in a load cycle and the terminal (≥ 1.0) emission
    /// always publish regardless of this window.
    var progressBridgeMinTransitionInterval: Duration = .milliseconds(250)

    /// Timestamp of the most recent published phase transition from
    /// ``applyModelLoadProgress``. `nil` means the next progress change will
    /// publish immediately (either because no progress has been published yet
    /// in this load cycle or a fresh cycle just began).
    @ObservationIgnored
    var lastProgressTransitionInstant: ContinuousClock.Instant?
    var lastPressureLevel: MemoryPressureLevel = .nominal
    private var isSynchronizingSelection = false
    var isRestoringSession = false

    /// Cached per-message token counts keyed by message ID, to avoid recalculating all messages.
    var tokenCountCache: [UUID: Int] = [:]

    /// Reusable caching tokenizer that persists across generation cycles.
    /// Invalidated when the underlying backend tokenizer changes (i.e. model swap).
    private var _cachingTokenizer: CachingTokenizer?
    /// Identity of the backend tokenizer the cached instance wraps, or `nil` when
    /// using the heuristic fallback. Used to detect model swaps.
    private var _cachingTokenizerBaseID: ObjectIdentifier?

    /// Returns a `CachingTokenizer` that persists across generation cycles,
    /// recreating it only when the underlying backend tokenizer changes.
    var reusableCachingTokenizer: CachingTokenizer {
        let backendTokenizer = inferenceService.tokenizer
        // Use ObjectIdentifier for reference-type tokenizers (e.g. LlamaBackend vends self),
        // fall back to type identity for value-type tokenizers (e.g. FoundationTokenizer).
        let newBaseID: ObjectIdentifier? = backendTokenizer.map {
            if let ref = $0 as? AnyObject { return ObjectIdentifier(ref) }
            return ObjectIdentifier(type(of: $0))
        }
        if let existing = _cachingTokenizer, _cachingTokenizerBaseID == newBaseID {
            return existing
        }
        let base: any TokenizerProvider = backendTokenizer ?? HeuristicTokenizer()
        let fresh = CachingTokenizer(wrapping: base)
        _cachingTokenizer = fresh
        _cachingTokenizerBaseID = newBaseID
        return fresh
    }

    /// Number of messages to load per page when paginating history.
    static let messagePageSize = SessionController.messagePageSize

    /// Whether older messages are available to load above the current page.
    public internal(set) var hasOlderMessages: Bool {
        get { sessionController.hasOlderMessages }
        set { sessionController.hasOlderMessages = newValue }
    }

    /// Whether a page of older messages is currently being fetched.
    public internal(set) var isLoadingOlderMessages: Bool {
        get { sessionController.isLoadingOlderMessages }
        set { sessionController.isLoadingOlderMessages = newValue }
    }

    // MARK: - Initialisation

    public convenience init(
        inferenceService: InferenceService = InferenceService(),
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService()
    ) {
        self.init(
            inferenceService: inferenceService,
            deviceCapability: deviceCapability,
            modelStorage: modelStorage,
            memoryPressure: MemoryPressureHandler()
        )
    }

    package init(
        inferenceService: InferenceService = InferenceService(),
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService(),
        memoryPressure: MemoryPressureHandler
    ) {
        self.inferenceService = inferenceService
        self.deviceCapability = deviceCapability
        self.modelStorage = modelStorage
        self.memoryPressure = memoryPressure
        self.sessionController = SessionController(selectedPromptTemplate: inferenceService.selectedPromptTemplate)

        if inferenceService.memoryGate == nil {
            inferenceService.memoryGate = MemoryGate()
        }

        let firstRunKey = "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch"
        self.isFirstRun = !UserDefaults.standard.bool(forKey: firstRunKey)
    }

    /// Injects the persistence provider. Call once from the view layer
    /// after the storage backend is available.
    public func configure(persistence: ChatPersistenceProvider) {
        sessionController.configure(persistence: persistence)
    }

    // MARK: - Structured Error Surfacing

    /// Surfaces an error with structured type information.
    func surfaceError(_ error: any Error, kind: ChatError.Kind, context: String? = nil) {
        activeError = ChatError.from(error, kind: kind, context: context)
    }
}

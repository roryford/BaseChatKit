import Foundation
import Observation
import SwiftData
import BaseChatCore

/// Central view model for the chat interface.
///
/// Manages the message history, model lifecycle, generation settings, context
/// tracking, export, and SwiftData persistence. Views observe this via
/// `@Environment` and never call services directly.
@Observable
@MainActor
public final class ChatViewModel {

    // MARK: - Services

    public let inferenceService: InferenceService
    let deviceCapability: DeviceCapabilityService
    let modelStorage: ModelStorageService
    let memoryPressure: MemoryPressureHandler
    let compressionOrchestrator = CompressionOrchestrator()

    // MARK: - Persistence

    var persistence: ChatPersistenceProvider?

    // MARK: - Session

    /// The currently active chat session. Set via `switchToSession(_:)`.
    public var activeSession: ChatSessionRecord?

    /// The session ID for the active session, or `nil` if no session is selected.
    var activeSessionID: UUID? { activeSession?.id }

    /// Called when a session might need its title auto-generated.
    /// Set by the view layer to connect to SessionManagerViewModel.
    public var onFirstMessage: ((ChatSessionRecord, String) -> Void)?

    // MARK: - First Run / Onboarding

    /// Called on the first launch instead of the default first-run behaviour.
    ///
    /// When set, this closure is invoked by `autoSelectFirstRunModel()` and the default
    /// Foundation model auto-selection is skipped entirely. If `nil`, the default
    /// behaviour auto-selects the Foundation model (if available); the model load itself
    /// is deferred to the view's `onChange(of: selectedModel)` handler to avoid a
    /// double-load race condition.
    public var onFirstLaunch: (() -> Void)?

    /// Returns `true` if the Foundation model backend is available on this device.
    /// Apps should set this to enable Foundation model auto-discovery.
    /// Example: `chatViewModel.foundationModelProvider = { FoundationBackend.isAvailable }`
    public var foundationModelProvider: (() -> Bool)?

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
    public internal(set) var messages: [ChatMessageRecord] = []

    /// The user's current input text.
    public var inputText: String = ""

    /// Editable system prompt prepended to every generation.
    public var systemPrompt: String = ""

    /// The current phase of backend activity, driving all status indicators.
    public internal(set) var activityPhase: BackendActivityPhase = .idle {
        didSet {
            let wasGenerating = oldValue == .waitingForFirstToken || oldValue == .streaming
            let nowGenerating = activityPhase == .waitingForFirstToken || activityPhase == .streaming
            if wasGenerating != nowGenerating {
                onGeneratingChanged?(nowGenerating)
            }
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

    // MARK: - Compression

    /// IDs of messages that are pinned in the current session.
    ///
    /// Pinned messages are excluded from context compression and always preserved
    /// in the conversation history. Populated from ``ChatSessionRecord/pinnedMessageIDs``
    /// when switching sessions. Persisted back to the session on changes.
    public internal(set) var pinnedMessageIDs: Set<UUID> = []

    /// The active compression mode. Synced to the orchestrator and persisted to the session.
    public var compressionMode: CompressionMode = .automatic {
        didSet {
            compressionOrchestrator.mode = compressionMode
            guard !isRestoringSession else { return }
            do {
                try saveSettingsToSession()
            } catch {
                Log.persistence.error("Failed to persist compression mode: \(error)")
                errorMessage = "Failed to save settings: \(error.localizedDescription)"
            }
        }
    }

    /// Statistics from the most recent compression pass, or `nil` if no compression occurred.
    public internal(set) var lastCompressionStats: CompressionStats?

    // MARK: - Tool Calling

    /// The active tool provider. When set, tools are passed to backends that
    /// adopt `ToolCallingBackend` before each generation call.
    public var toolProvider: (any ToolProvider)? {
        get { inferenceService.toolProvider }
        set { inferenceService.toolProvider = newValue }
    }

    /// Observer for tool call activity during generation. Set this to display
    /// tool calls and results in the UI as they happen.
    public var toolCallObserver: (any ToolCallObserver)? {
        get { inferenceService.toolCallObserver }
        set { inferenceService.toolCallObserver = newValue }
    }

    // MARK: - Generation Settings

    public var temperature: Float = 0.7
    public var topP: Float = 0.9
    public var repeatPenalty: Float = 1.1
    /// Minimum interval between batched UI updates during streaming (~30 fps by default).
    public var streamingUpdateInterval: Duration = .milliseconds(33)
    /// Maximum characters to buffer before forcing a UI flush during streaming.
    public var streamingBatchCharacterLimit: Int = 128

    /// Whether to automatically stop generation when repetitive looping is detected.
    /// Defaults to `true`. Disable for apps that handle loop detection themselves.
    public var loopDetectionEnabled: Bool = true

    /// Whether to expand macros (e.g., `{{user}}`, `{{date}}`) in the system prompt
    /// before generation. Defaults to `true`.
    public var macroExpansionEnabled: Bool = true

    /// Context values for macro expansion. Apps should populate fields relevant to
    /// their domain (e.g., `userName`, `charName`). Message-related fields
    /// (`lastMessage`, `lastUserMessage`, `lastCharMessage`) are auto-populated
    /// from the conversation history if left `nil`.
    public var macroContext: MacroContext = MacroContext()

    /// Prompt template for GGUF backends. Ignored by MLX/Foundation.
    public var selectedPromptTemplate: PromptTemplate {
        get { inferenceService.selectedPromptTemplate }
        set { inferenceService.selectedPromptTemplate = newValue }
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
    public var onUpgradeHintTriggered: (() -> Void)?

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

    var generationTask: Task<Void, Never>?
    var backgroundTask: Task<Void, Never>?
    var coordinatedLoadTask: Task<Void, Never>?
    var latestLoadIntentGeneration: UInt64 = 0
    var lastPressureLevel: MemoryPressureLevel = .nominal
    private var isSynchronizingSelection = false
    var isRestoringSession = false

    /// Cached per-message token counts keyed by message ID, to avoid recalculating all messages.
    var tokenCountCache: [UUID: Int] = [:]

    /// Number of messages to load per page when paginating history.
    static let messagePageSize = 50

    /// Whether older messages are available to load above the current page.
    public internal(set) var hasOlderMessages: Bool = false

    /// Whether a page of older messages is currently being fetched.
    public internal(set) var isLoadingOlderMessages: Bool = false

    // MARK: - Initialisation

    public init(
        inferenceService: InferenceService = InferenceService(),
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService(),
        memoryPressure: MemoryPressureHandler = MemoryPressureHandler()
    ) {
        self.inferenceService = inferenceService
        self.deviceCapability = deviceCapability
        self.modelStorage = modelStorage
        self.memoryPressure = memoryPressure

        if inferenceService.memoryGate == nil {
            inferenceService.memoryGate = MemoryGate()
        }

        let firstRunKey = "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch"
        self.isFirstRun = !UserDefaults.standard.bool(forKey: firstRunKey)

        compressionOrchestrator.anchored.generateFn = { [weak self] prompt in
            guard let self else { throw CancellationError() }
            let stream = try await MainActor.run {
                try self.inferenceService.generate(
                    messages: [(role: "user", content: prompt)],
                    systemPrompt: nil,
                    temperature: 0.3,
                    topP: 0.9,
                    repeatPenalty: 1.0
                )
            }
            var result = ""
            for try await event in stream {
                if case .token(let text) = event { result += text }
            }
            return result
        }
    }

    /// Injects the persistence provider. Call once from the view layer
    /// after the storage backend is available.
    public func configure(persistence: ChatPersistenceProvider) {
        guard self.persistence == nil else { return }
        self.persistence = persistence
        Log.persistence.info("ChatViewModel configured with persistence provider")
    }

    /// Convenience: wraps a SwiftData `ModelContext` in a ``SwiftDataPersistenceProvider``.
    @available(*, deprecated, message: "Use configure(persistence:) with an explicit provider")
    public func configure(modelContext: ModelContext) {
        configure(persistence: SwiftDataPersistenceProvider(modelContext: modelContext))
    }

    // MARK: - Structured Error Surfacing

    /// Surfaces an error with structured type information.
    func surfaceError(_ error: any Error, kind: ChatError.Kind, context: String? = nil) {
        activeError = ChatError.from(error, kind: kind, context: context)
    }
}

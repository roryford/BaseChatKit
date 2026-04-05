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
    private let deviceCapability: DeviceCapabilityService
    private let modelStorage: ModelStorageService
    private let memoryPressure: MemoryPressureHandler
    public let compressionOrchestrator = CompressionOrchestrator()

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
    public private(set) var availableModels: [ModelInfo] = []

    /// Enabled cloud endpoints available for selection.
    public private(set) var availableEndpoints: [APIEndpoint] = []

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
    public var onGeneratingChanged: ((Bool) -> Void)?

    /// A user-facing error message, shown as a banner. Cleared on next action.
    public var errorMessage: String?

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
    public var pinnedMessageIDs: Set<UUID> = []

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
    public private(set) var isFirstRun: Bool

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

    private enum LoadIntent {
        case localModel(ModelInfo)
        case cloudEndpoint(APIEndpoint)
    }

    var generationTask: Task<Void, Never>?
    var backgroundTask: Task<Void, Never>?
    private var coordinatedLoadTask: Task<Void, Never>?
    private var latestLoadIntentGeneration: UInt64 = 0
    private var lastPressureLevel: MemoryPressureLevel = .nominal
    private var isSynchronizingSelection = false
    private var isRestoringSession = false

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
            for try await token in stream { result += token }
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

    // MARK: - Session Management

    /// Switches to a different chat session, loading its messages and settings.
    public func switchToSession(_ session: ChatSessionRecord) {
        isRestoringSession = true
        defer { isRestoringSession = false }

        activeSession = session
        inferenceService.resetConversation()

        // Cancel any in-flight post-generation background tasks from the prior session.
        backgroundTask?.cancel()
        backgroundTask = nil

        // Load session's generation settings (fall back to defaults)
        systemPrompt = session.systemPrompt
        temperature = session.temperature ?? 0.7
        topP = session.topP ?? 0.9
        repeatPenalty = session.repeatPenalty ?? 1.1

        // Load prompt template if session has one
        if let template = session.promptTemplate {
            selectedPromptTemplate = template
        }

        let resolvedEndpoint = session.selectedEndpointID.flatMap { endpointID in
            availableEndpoints.first(where: { $0.id == endpointID })
        }
        let resolvedModel = session.selectedModelID.flatMap { modelID in
            availableModels.first(where: { $0.id == modelID })
        }

        if let resolvedEndpoint {
            selectedEndpoint = resolvedEndpoint
        } else if let resolvedModel {
            selectedModel = resolvedModel
        } else {
            selectedModel = nil
            selectedEndpoint = nil
        }

        // pinnedMessageIDs must be set before compressionMode: the compressionMode
        // didSet calls saveSettingsToSession(), which writes pinnedMessageIDs back to
        // the session. Setting pins first ensures the correct value is persisted.
        pinnedMessageIDs = session.pinnedMessageIDs
        compressionMode = session.compressionMode

        showUpgradeHint = false
        loadMessages()
        updateContextEstimate()
        Log.ui.info("Switched to session: \(session.title, privacy: .private)")
    }

    /// Saves the current generation settings back to the active session.
    public func saveSettingsToSession() throws {
        guard var session = activeSession else { return }
        guard let persistence else {
            Log.persistence.warning("saveSettingsToSession called before persistence was configured")
            throw ChatPersistenceError.providerNotConfigured
        }
        session.temperature = temperature
        session.topP = topP
        session.repeatPenalty = repeatPenalty
        session.systemPrompt = systemPrompt
        session.selectedModelID = selectedModel?.id
        session.selectedEndpointID = selectedEndpoint?.id
        session.compressionMode = compressionMode
        session.pinnedMessageIDs = pinnedMessageIDs
        session.updatedAt = Date()
        try persistence.updateSession(session)
        activeSession = session
    }

    // MARK: - Model Discovery

    /// Re-scans the models directory and rebuilds `availableModels`.
    ///
    /// Includes the built-in Foundation model when `foundationModelProvider` returns `true`.
    /// Clears `selectedModel` if the previously selected model is no longer on disk.
    public func refreshModels() {
        do {
            try modelStorage.ensureModelsDirectory()
        } catch {
            errorMessage = "Could not create models directory: \(error.localizedDescription)"
        }

        var models: [ModelInfo] = []

        // Let the app inject Foundation model availability check
        if let provider = foundationModelProvider, provider() {
            models.append(.builtInFoundation)
        }

        models.append(contentsOf: modelStorage.discoverModels())
        availableModels = models

        if let selected = selectedModel, !availableModels.contains(where: { $0.id == selected.id }) {
            selectedModel = nil
        }
    }

    /// Replaces the in-memory list of selectable cloud endpoints.
    ///
    /// Clears `selectedEndpoint` when that endpoint is no longer available.
    public func setAvailableEndpoints(_ endpoints: [APIEndpoint]) {
        availableEndpoints = endpoints
        if let selected = selectedEndpoint,
           !availableEndpoints.contains(where: { $0.id == selected.id }) {
            selectedEndpoint = nil
        }
    }

    /// On first launch, runs the `onFirstLaunch` closure if set; otherwise falls
    /// back to auto-selecting the Foundation model and eagerly loading it.
    ///
    /// Apps can customise first-run behaviour by setting `onFirstLaunch` before
    /// calling this method.
    public func autoSelectFirstRunModel() {
        let key = "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        isFirstRun = false

        if let customHandler = onFirstLaunch {
            customHandler()
            return
        }

        // Default behaviour: auto-select Foundation model if available.
        guard let foundation = availableModels.first(where: { $0.modelType == .foundation }) else {
            return
        }

        selectedModel = foundation
        Log.ui.info("Auto-selected Foundation model for first launch")
        // Note: do NOT call loadSelectedModel() here — the selection-change
        // handlers in the view coordinate the load. Calling it here causes a double-load
        // race where the second load unloads the first mid-flight.
    }

    // MARK: - Model Loading

    // Two-tier load coordination:
    // - ChatViewModel (this layer) owns UI task lifecycle via `latestLoadIntentGeneration` —
    //   superseded async tasks are cancelled before they reach InferenceService.
    // - InferenceService owns backend state correctness via monotonic LoadRequestToken —
    //   any stale completion that does reach the service layer is suppressed there.
    // Together they provide defense-in-depth: this layer avoids redundant load attempts;
    // InferenceService provides the hard correctness guarantee.

    /// Coordinates loading for the currently selected model/endpoint.
    ///
    /// Newest selection always wins; any older in-flight coordinated load intent is
    /// cancelled and invalidated.
    public func dispatchSelectedLoad() {
        let generation = nextLoadIntentGeneration(cancelInFlightTask: true)
        guard let intent = currentLoadIntent else { return }

        coordinatedLoadTask = Task { [weak self] in
            await self?.performLoad(intent, generation: generation)
        }
    }

    /// Manually unloads the active backend and invalidates any pending coordinated load.
    public func unloadModel() {
        invalidatePendingLoadIntent(resetActivityPhase: true)
        inferenceService.unloadModel()
    }

    /// Loads the currently selected local model into the inference backend.
    ///
    /// Does nothing if a load is already in progress. Sets `isLoading` for the duration
    /// and writes to `errorMessage` on failure. Auto-detects the GGUF prompt template
    /// from model metadata before loading.
    ///
    /// - Note: Prefer `dispatchSelectedLoad()` for UI-driven loads — it coordinates
    ///   intent and cancels superseded requests.
    public func loadSelectedModel() async {
        guard !isLoading else { return }

        guard let model = selectedModel else {
            errorMessage = "No model selected."
            return
        }

        await loadLocalModel(model, generation: nil)
    }

    // MARK: - Cloud Endpoint Loading

    /// Loads a cloud API endpoint for the active session.
    ///
    /// - Note: Prefer `dispatchSelectedLoad()` for UI-driven loads — it coordinates
    ///   intent and cancels superseded requests.
    public func loadCloudEndpoint(_ endpoint: APIEndpoint) async {
        await loadCloudEndpointInternal(endpoint, generation: nil)
    }

    private var currentLoadIntent: LoadIntent? {
        if let endpoint = selectedEndpoint {
            return .cloudEndpoint(endpoint)
        }
        if let model = selectedModel {
            return .localModel(model)
        }
        return nil
    }

    @discardableResult
    private func nextLoadIntentGeneration(cancelInFlightTask: Bool) -> UInt64 {
        latestLoadIntentGeneration &+= 1
        if cancelInFlightTask {
            coordinatedLoadTask?.cancel()
            coordinatedLoadTask = nil
        }
        return latestLoadIntentGeneration
    }

    private func invalidatePendingLoadIntent(resetActivityPhase: Bool = false) {
        _ = nextLoadIntentGeneration(cancelInFlightTask: true)
        if resetActivityPhase, isLoading {
            activityPhase = .idle
        }
    }

    private func isCurrentLoadIntentGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return generation == latestLoadIntentGeneration
    }

    private func beginLoadUIState(generation: UInt64?) -> Bool {
        guard isCurrentLoadIntentGeneration(generation) else { return false }
        errorMessage = nil
        activityPhase = .modelLoading(progress: nil)
        return true
    }

    private func endLoadUIState(generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        if case .modelLoading = activityPhase {
            activityPhase = .idle
        }
    }

    private func setLoadErrorIfCurrent(_ message: String, generation: UInt64?) {
        guard isCurrentLoadIntentGeneration(generation) else { return }
        errorMessage = message
    }

    private func performLoad(_ intent: LoadIntent, generation: UInt64?) async {
        switch intent {
        case .localModel(let model):
            await loadLocalModel(model, generation: generation)
        case .cloudEndpoint(let endpoint):
            await loadCloudEndpointInternal(endpoint, generation: generation)
        }
    }

    private func loadLocalModel(_ model: ModelInfo, generation: UInt64?) async {
        guard isCurrentLoadIntentGeneration(generation) else { return }

        if model.modelType != .foundation {
            guard deviceCapability.canLoadModel(estimatedMemoryBytes: model.fileSize) else {
                let ramGB = deviceCapability.physicalMemory / (1024 * 1024 * 1024)
                setLoadErrorIfCurrent(
                    "This model (\(model.fileSizeFormatted)) may be too large for this device (\(ramGB) GB RAM). Try a smaller quantisation.",
                    generation: generation
                )
                return
            }
        }

        // Auto-detect prompt template from GGUF metadata before loading.
        if let detected = model.detectedPromptTemplate,
           isCurrentLoadIntentGeneration(generation) {
            selectedPromptTemplate = detected
            Log.inference.info("Auto-detected prompt template: \(detected.rawValue)")
        }

        guard beginLoadUIState(generation: generation) else { return }
        defer { endLoadUIState(generation: generation) }

        do {
            let contextSize: Int32 = Int32(model.detectedContextLength ?? 2048)
            try await inferenceService.loadModel(from: model, contextSize: contextSize)
        } catch is CancellationError {
            return
        } catch {
            setLoadErrorIfCurrent("Failed to load model: \(error.localizedDescription)", generation: generation)
        }
    }

    private func loadCloudEndpointInternal(_ endpoint: APIEndpoint, generation: UInt64?) async {
        guard beginLoadUIState(generation: generation) else { return }
        defer { endLoadUIState(generation: generation) }

        do {
            try await inferenceService.loadCloudBackend(from: endpoint)
        } catch is CancellationError {
            return
        } catch {
            setLoadErrorIfCurrent("Failed to connect: \(error.localizedDescription)", generation: generation)
        }
    }

    // MARK: - Chat

    /// Sends the current input as a user message and generates an assistant response.
    public func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let activeSessionID else {
            errorMessage = "No active session. Create or select a session first."
            return
        }

        guard isModelLoaded else {
            errorMessage = "No model loaded. Select a model from the sidebar first."
            return
        }

        errorMessage = nil
        inputText = ""
        Log.ui.debug("User sent message")

        // Create and persist the user message.
        let userMessage = ChatMessageRecord(role: .user, content: text, sessionID: activeSessionID)
        messages.append(userMessage)
        do {
            try saveMessage(userMessage)
        } catch {
            Log.persistence.error("Failed to save user message: \(error)")
            errorMessage = "Failed to save message: \(error.localizedDescription)"
            messages.removeAll(where: { $0.id == userMessage.id })
            return
        }

        // Update session timestamp.
        activeSession?.updatedAt = Date()

        // Trigger auto-title on the first user message in this session.
        if let session = activeSession, messages.filter({ $0.role == .user }).count == 1 {
            onFirstMessage?(session, text)
        }

        // Create an empty assistant message that will be streamed into.
        let assistantMessage = ChatMessageRecord(role: .assistant, content: "", sessionID: activeSessionID)
        messages.append(assistantMessage)

        await generateIntoMessage(assistantMessage)
        updateContextEstimate()
    }

    /// Regenerates the last assistant response.
    public func regenerateLastResponse() async {
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        // Find and remove the last assistant message.
        guard let lastAssistantIndex = messages.lastIndex(where: { $0.role == .assistant }) else {
            return
        }

        let removed = messages.remove(at: lastAssistantIndex)
        do {
            try deleteMessage(removed)
        } catch {
            Log.persistence.error("Failed to delete prior assistant message: \(error)")
            errorMessage = "Failed to regenerate response: \(error.localizedDescription)"
            messages.insert(removed, at: lastAssistantIndex)
            return
        }

        // Create a fresh assistant message.
        let assistantMessage = ChatMessageRecord(role: .assistant, content: "", sessionID: activeSessionID)
        messages.append(assistantMessage)

        Log.ui.debug("Regenerating last response")
        await generateIntoMessage(assistantMessage)
    }

    /// Edits a message and regenerates everything after it.
    public func editMessage(_ messageID: UUID, newContent: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        // Update the edited message.
        let originalMessage = messages[index]
        messages[index].content = newContent
        do {
            try updateMessage(messages[index])
        } catch {
            messages[index] = originalMessage
            Log.persistence.error("Failed to update edited message: \(error)")
            errorMessage = "Failed to edit message: \(error.localizedDescription)"
            return
        }

        // Remove all messages after the edited one.
        let toRemove = Array(messages[(index + 1)...])
        messages.removeSubrange((index + 1)...)
        for msg in toRemove {
            do {
                try deleteMessage(msg)
            } catch {
                Log.persistence.error("Failed to delete message during edit regeneration: \(error)")
                errorMessage = "Failed to regenerate conversation: \(error.localizedDescription)"
                messages = Array(messages.prefix(index + 1)) + toRemove
                return
            }
        }

        // If the edited message was from the user, regenerate the assistant response.
        if messages[index].role == .user {
            let assistantMessage = ChatMessageRecord(role: .assistant, content: "", sessionID: activeSessionID)
            messages.append(assistantMessage)
            Log.ui.debug("Edited user message, regenerating")
            await generateIntoMessage(assistantMessage)
        }
    }

    /// Stops an in-progress generation.
    public func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        inferenceService.stopGeneration()
        activityPhase = .idle

        // Persist whatever has been generated so far.
        if let lastAssistant = messages.last(where: { $0.role == .assistant }),
           !lastAssistant.content.isEmpty {
            do {
                try saveMessage(lastAssistant)
            } catch {
                Log.persistence.error("Failed to persist partial assistant message: \(error)")
                errorMessage = "Failed to save partial response: \(error.localizedDescription)"
            }
        }
        Log.ui.debug("Generation stopped by user")
    }

    /// Clears all messages in the current session.
    ///
    /// Cancels any in-flight generation before clearing to avoid inconsistent UI state.
    public func clearChat() {
        if isGenerating {
            stopGeneration()
        }

        // Cancel any in-flight post-generation background tasks.
        backgroundTask?.cancel()
        backgroundTask = nil

        guard let activeSessionID else {
            messages.removeAll()
            tokenCountCache.removeAll()
            hasOlderMessages = false
            updateContextEstimate()
            Log.ui.info("Chat cleared")
            return
        }

        do {
            try deleteMessages(for: activeSessionID)
            messages.removeAll()
            tokenCountCache.removeAll()
            hasOlderMessages = false
            updateContextEstimate()
            Log.ui.info("Chat cleared")
        } catch {
            Log.persistence.error("Failed to delete messages while clearing chat: \(error)")
            loadMessages()
            tokenCountCache.removeAll()
            updateContextEstimate()
            errorMessage = "Failed to clear chat: \(error.localizedDescription)"
            return
        }
    }

    // MARK: - Export

    /// Exports the current chat in the specified format.
    public func exportChat(format: ExportFormat) -> String {
        ChatExportService.export(
            messages: messages,
            sessionTitle: activeSession?.title ?? "Chat",
            format: format
        )
    }

    // MARK: - Lifecycle

    /// Saves all pending changes. Called on app background.
    public func saveState() {
        do {
            try saveSettingsToSession()
            Log.persistence.info("State saved on background")
        } catch {
            Log.persistence.error("Failed to save state on background: \(error)")
            errorMessage = "Failed to save state: \(error.localizedDescription)"
        }
    }

    // MARK: - Memory Pressure Monitoring

    public func startMemoryMonitoring() {
        memoryPressure.startMonitoring()
    }

    public func stopMemoryMonitoring() {
        memoryPressure.stopMonitoring()
    }

    public func handleMemoryPressure() {
        let level = memoryPressure.pressureLevel
        guard level != lastPressureLevel else { return }
        lastPressureLevel = level

        switch level {
        case .critical:
            stopGeneration()
            unloadModel()
            errorMessage = "Memory pressure is critical. The model was unloaded to prevent the app from being terminated."
        case .warning:
            errorMessage = "Memory pressure is elevated. Consider closing other apps."
        case .nominal:
            if errorMessage?.contains("Memory pressure") == true {
                errorMessage = nil
            }
        }
    }

    // MARK: - Message Pinning

    /// Marks a message as pinned, preserving it from context compression.
    public func pinMessage(id messageID: UUID) {
        pinnedMessageIDs.insert(messageID)
        do {
            try saveSettingsToSession()
        } catch {
            Log.persistence.error("Failed to save pinned message settings: \(error)")
            errorMessage = "Failed to pin message: \(error.localizedDescription)"
        }
    }

    /// Removes the pin from a message.
    public func unpinMessage(id messageID: UUID) {
        pinnedMessageIDs.remove(messageID)
        do {
            try saveSettingsToSession()
        } catch {
            Log.persistence.error("Failed to save unpinned message settings: \(error)")
            errorMessage = "Failed to unpin message: \(error.localizedDescription)"
        }
    }

    /// Returns whether the given message is currently pinned.
    public func isMessagePinned(id messageID: UUID) -> Bool {
        pinnedMessageIDs.contains(messageID)
    }
}

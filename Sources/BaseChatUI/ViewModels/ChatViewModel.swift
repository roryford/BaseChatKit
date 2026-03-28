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

    // MARK: - Persistence

    var modelContext: ModelContext?

    // MARK: - Session

    /// The currently active chat session. Set via `switchToSession(_:)`.
    public var activeSession: ChatSession?

    /// The session ID for the active session, or `nil` if no session is selected.
    var activeSessionID: UUID? { activeSession?.id }

    /// Called when a session might need its title auto-generated.
    /// Set by the view layer to connect to SessionManagerViewModel.
    public var onFirstMessage: ((ChatSession, String) -> Void)?

    // MARK: - First Run / Onboarding

    /// Called on the first launch. Override to provide custom onboarding behaviour.
    /// The default implementation auto-selects the Foundation model (if available)
    /// and eagerly loads it.
    public var onFirstLaunch: (() -> Void)?

    /// Returns `true` if the Foundation model backend is available on this device.
    /// Apps should set this to enable Foundation model auto-discovery.
    /// Example: `chatViewModel.foundationModelProvider = { FoundationBackend.isAvailable }`
    public var foundationModelProvider: (() -> Bool)?

    // MARK: - Published State

    /// All models discovered on disk plus the built-in Foundation model.
    public private(set) var availableModels: [ModelInfo] = []

    /// The model the user has selected in the sidebar.
    public var selectedModel: ModelInfo?

    /// The cloud API endpoint the user has selected, or `nil` for local models.
    /// Setting this clears `selectedModel` and vice versa.
    public var selectedEndpoint: APIEndpoint?

    /// Ordered messages for the active session.
    public internal(set) var messages: [ChatMessage] = []

    /// The user's current input text.
    public var inputText: String = ""

    /// Editable system prompt prepended to every generation.
    public var systemPrompt: String = ""

    /// Whether a model is currently being loaded.
    public private(set) var isLoading: Bool = false

    /// Whether inference is currently streaming tokens.
    public internal(set) var isGenerating: Bool = false

    /// A user-facing error message, shown as a banner. Cleared on next action.
    public var errorMessage: String?

    // MARK: - Generation Settings

    public var temperature: Float = 0.7
    public var topP: Float = 0.9
    public var repeatPenalty: Float = 1.1

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

    var generationTask: Task<Void, Never>?
    private var lastPressureLevel: MemoryPressureLevel = .nominal

    /// Cached per-message token counts keyed by message ID, to avoid recalculating all messages.
    var tokenCountCache: [UUID: Int] = [:]

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

        let firstRunKey = "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch"
        self.isFirstRun = !UserDefaults.standard.bool(forKey: firstRunKey)
    }

    /// Injects the SwiftData model context. Call once from the view layer
    /// after the model container is available.
    public func configure(modelContext: ModelContext) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        Log.persistence.info("ChatViewModel configured with ModelContext")
    }

    // MARK: - Session Management

    /// Switches to a different chat session, loading its messages and settings.
    public func switchToSession(_ session: ChatSession) {
        activeSession = session

        // Load session's generation settings (fall back to defaults)
        systemPrompt = session.systemPrompt
        temperature = session.temperature ?? 0.7
        topP = session.topP ?? 0.9
        repeatPenalty = session.repeatPenalty ?? 1.1

        // Load prompt template if session has one
        if let template = session.promptTemplate {
            selectedPromptTemplate = template
        }

        // Try to select the session's model
        if let modelID = session.selectedModelID,
           let model = availableModels.first(where: { $0.id == modelID }) {
            selectedModel = model
        }

        showUpgradeHint = false
        loadMessages()
        updateContextEstimate()
        Log.ui.info("Switched to session: \(session.title, privacy: .private)")
    }

    /// Saves the current generation settings back to the active session.
    public func saveSettingsToSession() {
        guard let session = activeSession else { return }
        session.temperature = temperature
        session.topP = topP
        session.repeatPenalty = repeatPenalty
        session.systemPrompt = systemPrompt
        session.selectedModelID = selectedModel?.id
        session.updatedAt = Date()

        do {
            try modelContext?.save()
        } catch {
            Log.persistence.error("Failed to save session settings: \(error)")
        }
    }

    // MARK: - Model Discovery

    /// Re-scans the models directory and updates the available models list.
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
        Log.ui.info("Auto-selected Foundation model for first launch — loading eagerly")

        Task {
            await loadSelectedModel()
        }
    }

    // MARK: - Model Loading

    public func loadSelectedModel() async {
        guard !isLoading else { return }

        guard let model = selectedModel else {
            errorMessage = "No model selected."
            return
        }

        if model.modelType != .foundation {
            guard deviceCapability.canLoadModel(estimatedMemoryBytes: model.fileSize) else {
                let ramGB = deviceCapability.physicalMemory / (1024 * 1024 * 1024)
                errorMessage = "This model (\(model.fileSizeFormatted)) may be too large for this device (\(ramGB) GB RAM). Try a smaller quantisation."
                return
            }
        }

        // Auto-detect prompt template from GGUF metadata before loading.
        if let detected = model.detectedPromptTemplate {
            selectedPromptTemplate = detected
            Log.inference.info("Auto-detected prompt template: \(detected.rawValue)")
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let contextSize: Int32 = Int32(model.detectedContextLength ?? 2048)
            try await inferenceService.loadModel(from: model, contextSize: contextSize)
        } catch {
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
    }

    // MARK: - Cloud Endpoint Loading

    /// Loads a cloud API endpoint for the active session.
    public func loadCloudEndpoint(_ endpoint: APIEndpoint) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await inferenceService.loadCloudBackend(from: endpoint)
        } catch {
            errorMessage = "Failed to connect: \(error.localizedDescription)"
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
        let userMessage = ChatMessage(role: .user, content: text, sessionID: activeSessionID)
        messages.append(userMessage)
        saveMessage(userMessage)

        // Update session timestamp.
        activeSession?.updatedAt = Date()

        // Trigger auto-title on the first user message in this session.
        if let session = activeSession, messages.filter({ $0.role == .user }).count == 1 {
            onFirstMessage?(session, text)
        }

        // Create an empty assistant message that will be streamed into.
        let assistantMessage = ChatMessage(role: .assistant, content: "", sessionID: activeSessionID)
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
        deleteMessage(removed)

        // Create a fresh assistant message.
        let assistantMessage = ChatMessage(role: .assistant, content: "", sessionID: activeSessionID)
        messages.append(assistantMessage)

        Log.ui.debug("Regenerating last response")
        await generateIntoMessage(assistantMessage)
    }

    /// Edits a message and regenerates everything after it.
    public func editMessage(_ message: ChatMessage, newContent: String) async {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        // Update the edited message.
        message.content = newContent
        saveMessage(message)

        // Remove all messages after the edited one.
        let toRemove = Array(messages[(index + 1)...])
        messages.removeSubrange((index + 1)...)
        for msg in toRemove {
            deleteMessage(msg)
        }

        // If the edited message was from the user, regenerate the assistant response.
        if message.role == .user {
            let assistantMessage = ChatMessage(role: .assistant, content: "", sessionID: activeSessionID)
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
        isGenerating = false

        // Persist whatever has been generated so far.
        if let lastAssistant = messages.last(where: { $0.role == .assistant }),
           !lastAssistant.content.isEmpty {
            saveMessage(lastAssistant)
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
        for message in messages {
            deleteMessage(message)
        }
        messages.removeAll()
        tokenCountCache.removeAll()
        updateContextEstimate()
        Log.ui.info("Chat cleared")
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
        guard let modelContext else {
            Log.persistence.warning("saveState called before modelContext was configured — state will not be saved")
            return
        }
        do {
            try modelContext.save()
            Log.persistence.info("State saved on background")
        } catch {
            Log.persistence.error("Failed to save state: \(error)")
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
            inferenceService.unloadModel()
            errorMessage = "Memory pressure is critical. The model was unloaded to prevent the app from being terminated."
        case .warning:
            errorMessage = "Memory pressure is elevated. Consider closing other apps."
        case .nominal:
            if errorMessage?.contains("Memory pressure") == true {
                errorMessage = nil
            }
        }
    }
}

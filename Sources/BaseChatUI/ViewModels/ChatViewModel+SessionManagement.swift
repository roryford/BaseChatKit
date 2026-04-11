import Foundation
import SwiftData
import BaseChatCore

// MARK: - ChatViewModel + Session Management

extension ChatViewModel {

    /// Switches to a different chat session, loading its messages and settings.
    public func switchToSession(_ session: ChatSessionRecord) {
        // Stop any active generation for the old session.
        if isGenerating {
            stopGeneration()
        }

        isRestoringSession = true
        defer { isRestoringSession = false }

        activeSession = session
        inferenceService.resetConversation()

        // Discard any queued requests that belong to a different session.
        inferenceService.discardRequests(notMatching: session.id)

        // Cancel any in-flight post-generation background tasks from the prior session.
        backgroundTask?.cancel()
        backgroundTask = nil
        backgroundTaskError = nil

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

        pinnedMessageIDs = session.pinnedMessageIDs

        showUpgradeHint = false
        loadMessages()
        updateContextEstimate()
        Log.ui.info("Switched to session: \(session.title, privacy: .private)")
    }

    /// Saves the current generation settings back to the active session.
    func saveSettingsToSession() throws {
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
}

import Foundation
import BaseChatCore

// MARK: - ChatViewModel + Messages

extension ChatViewModel {

    /// Sends the current input as a user message and generates an assistant response.
    public func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let activeSessionID else {
            errorMessage = "No active session. Create or select a session first."
            return
        }

        guard isModelLoaded else {
            activeError = ChatError(kind: .configuration, message: "No model loaded. Select a model from the sidebar first.", recovery: .selectModel)
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
            surfaceError(error, kind: .persistence)
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
            surfaceError(error, kind: .persistence)
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
            surfaceError(error, kind: .persistence)
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
                surfaceError(error, kind: .persistence)
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
        activeGenerationToken = nil
        inferenceService.stopGeneration()
        transitionPhase(to: .idle)

        // Persist whatever has been generated so far.
        if let lastAssistant = messages.last(where: { $0.role == .assistant }),
           !lastAssistant.content.isEmpty {
            do {
                try saveMessage(lastAssistant)
            } catch {
                Log.persistence.error("Failed to persist partial assistant message: \(error)")
                surfaceError(error, kind: .persistence)
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
            surfaceError(error, kind: .persistence)
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

    // MARK: - Message Pinning

    /// Marks a message as pinned, preserving it from context compression.
    public func pinMessage(id messageID: UUID) {
        pinnedMessageIDs.insert(messageID)
        do {
            try saveSettingsToSession()
        } catch {
            Log.persistence.error("Failed to save pinned message settings: \(error)")
            surfaceError(error, kind: .persistence)
        }
    }

    /// Removes the pin from a message.
    public func unpinMessage(id messageID: UUID) {
        pinnedMessageIDs.remove(messageID)
        do {
            try saveSettingsToSession()
        } catch {
            Log.persistence.error("Failed to save unpinned message settings: \(error)")
            surfaceError(error, kind: .persistence)
        }
    }

    /// Returns whether the given message is currently pinned.
    public func isMessagePinned(id messageID: UUID) -> Bool {
        pinnedMessageIDs.contains(messageID)
    }
}

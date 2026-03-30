import Foundation
import BaseChatCore

// MARK: - ChatViewModel + Persistence

extension ChatViewModel {

    /// Loads messages for the active session from the persistence provider.
    func loadMessages() {
        guard let persistence else {
            Log.persistence.warning("loadMessages called before persistence was configured — messages will not load")
            return
        }
        guard let sessionID = activeSessionID else {
            messages = []
            return
        }

        do {
            messages = try persistence.fetchMessages(for: sessionID)
            Log.persistence.info("Loaded \(self.messages.count) messages")
        } catch {
            Log.persistence.error("Failed to load messages: \(error)")
            messages = []
        }
    }

    /// Persists a message via the persistence provider.
    func saveMessage(_ message: ChatMessageRecord) {
        guard let persistence else {
            Log.persistence.warning("saveMessage called before persistence was configured — message will not be persisted")
            return
        }
        do {
            try persistence.insertMessage(message)
        } catch {
            Log.persistence.error("Failed to save message: \(error)")
        }
    }

    /// Deletes a message via the persistence provider.
    func deleteMessage(_ message: ChatMessageRecord) {
        guard let persistence else {
            Log.persistence.warning("deleteMessage called before persistence was configured — message will not be deleted")
            return
        }
        do {
            try persistence.deleteMessage(message.id)
        } catch {
            Log.persistence.error("Failed to delete message: \(error)")
        }
    }
}

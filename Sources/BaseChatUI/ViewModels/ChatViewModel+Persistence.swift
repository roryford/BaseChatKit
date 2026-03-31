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
    func saveMessage(_ message: ChatMessageRecord) throws {
        guard let persistence else {
            Log.persistence.warning("saveMessage called before persistence was configured — message will not be persisted")
            return
        }
        try persistence.insertMessage(message)
    }

    /// Updates an existing message via the persistence provider.
    func updateMessage(_ message: ChatMessageRecord) throws {
        guard let persistence else {
            Log.persistence.warning("updateMessage called before persistence was configured — message will not be updated")
            return
        }
        try persistence.updateMessage(message)
    }

    /// Deletes a message via the persistence provider.
    func deleteMessage(_ message: ChatMessageRecord) throws {
        guard let persistence else {
            Log.persistence.warning("deleteMessage called before persistence was configured — message will not be deleted")
            return
        }
        try persistence.deleteMessage(message.id)
    }

    /// Deletes all messages for a session via the persistence provider.
    func deleteMessages(for sessionID: UUID) throws {
        guard let persistence else {
            Log.persistence.warning("deleteMessages called before persistence was configured — messages will not be deleted")
            return
        }
        try persistence.deleteMessages(for: sessionID)
    }
}

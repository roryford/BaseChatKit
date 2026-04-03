import Foundation
import BaseChatCore

// MARK: - ChatViewModel + Persistence

extension ChatViewModel {

    /// Loads the most recent page of messages for the active session.
    func loadMessages() {
        guard let persistence else {
            Log.persistence.warning("loadMessages called before persistence was configured — messages will not load")
            return
        }
        guard let sessionID = activeSessionID else {
            messages = []
            hasOlderMessages = false
            return
        }

        do {
            let page = try persistence.fetchRecentMessages(for: sessionID, limit: Self.messagePageSize)
            messages = page
            // If we got a full page, there may be older messages above.
            hasOlderMessages = page.count >= Self.messagePageSize
            Log.persistence.info("Loaded \(page.count) messages (hasOlder: \(self.hasOlderMessages))")
        } catch {
            Log.persistence.error("Failed to load messages: \(error)")
            messages = []
            hasOlderMessages = false
        }
    }

    /// Loads the next page of older messages and prepends them.
    ///
    /// Returns the ID of the message that was previously first in the list,
    /// so the caller can restore scroll position to it after the prepend.
    @discardableResult
    public func loadOlderMessages() -> UUID? {
        guard !isLoadingOlderMessages, hasOlderMessages else { return nil }
        guard let persistence else { return nil }
        guard let sessionID = activeSessionID else { return nil }
        guard let oldestTimestamp = messages.first?.timestamp else { return nil }

        let anchorID = messages.first?.id
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        do {
            let older = try persistence.fetchMessages(for: sessionID, before: oldestTimestamp, limit: Self.messagePageSize)
            if older.isEmpty {
                hasOlderMessages = false
                return anchorID
            }
            hasOlderMessages = older.count >= Self.messagePageSize
            messages.insert(contentsOf: older, at: 0)
            Log.persistence.info("Prepended \(older.count) older messages (hasOlder: \(self.hasOlderMessages))")
        } catch {
            Log.persistence.error("Failed to load older messages: \(error)")
        }

        return anchorID
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

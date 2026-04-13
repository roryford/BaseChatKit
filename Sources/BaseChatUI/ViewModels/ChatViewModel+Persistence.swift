import Foundation
import BaseChatCore
import BaseChatInference

// MARK: - ChatViewModel + Persistence

extension ChatViewModel {

    /// Loads the most recent page of messages for the active session.
    func loadMessages() {
        sessionController.loadMessages()
    }

    /// Loads the next page of older messages and prepends them.
    ///
    /// Returns the ID of the message that was previously first in the list,
    /// so the caller can restore scroll position to it after the prepend.
    @discardableResult
    public func loadOlderMessages() -> UUID? {
        sessionController.loadOlderMessages()
    }

    /// Persists a message via the persistence provider.
    ///
    /// `ChatViewModel` calls this for both brand-new messages and later writes to
    /// the same logical message (for example, when a cancelled assistant reply is
    /// saved once from `stopGeneration()` and again at the end of
    /// `generateIntoMessage`). Treat it as an upsert at the view-model boundary so
    /// callers do not need to coordinate insert vs. update ownership.
    func saveMessage(_ message: ChatMessageRecord) throws {
        try sessionController.saveMessage(message)
    }

    /// Updates an existing message via the persistence provider.
    func updateMessage(_ message: ChatMessageRecord) throws {
        try sessionController.updateMessage(message)
    }

    /// Deletes a message via the persistence provider.
    func deleteMessage(_ message: ChatMessageRecord) throws {
        try sessionController.deleteMessage(message)
    }

    /// Deletes all messages for a session via the persistence provider.
    func deleteMessages(for sessionID: UUID) throws {
        try sessionController.deleteMessages(for: sessionID)
    }
}

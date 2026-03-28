import Foundation
import SwiftData
import BaseChatCore

// MARK: - ChatViewModel + Persistence

extension ChatViewModel {

    /// Loads messages for the active session from SwiftData.
    func loadMessages() {
        guard let modelContext else {
            Log.persistence.warning("loadMessages called before modelContext was configured — messages will not load")
            return
        }
        guard let sessionID = activeSessionID else {
            messages = []
            return
        }

        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )

        do {
            messages = try modelContext.fetch(descriptor)
            Log.persistence.info("Loaded \(self.messages.count) messages")
        } catch {
            Log.persistence.error("Failed to load messages: \(error)")
            messages = []
        }
    }

    /// Persists a message to SwiftData.
    func saveMessage(_ message: ChatMessage) {
        guard let modelContext else {
            Log.persistence.warning("saveMessage called before modelContext was configured — message will not be persisted")
            return
        }
        modelContext.insert(message)
        do {
            try modelContext.save()
        } catch {
            Log.persistence.error("Failed to save message: \(error)")
        }
    }

    /// Deletes a message from SwiftData.
    func deleteMessage(_ message: ChatMessage) {
        guard let modelContext else {
            Log.persistence.warning("deleteMessage called before modelContext was configured — message will not be deleted")
            return
        }
        modelContext.delete(message)
        do {
            try modelContext.save()
        } catch {
            Log.persistence.error("Failed to delete message: \(error)")
        }
    }
}

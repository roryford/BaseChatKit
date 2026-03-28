import Foundation
import Observation
import SwiftData
import BaseChatCore

/// Manages chat session CRUD operations and the session list.
@Observable
public final class SessionManagerViewModel {

    /// All sessions, sorted by most recently updated.
    public private(set) var sessions: [ChatSession] = []

    /// The currently active session.
    public var activeSession: ChatSession?

    private var modelContext: ModelContext?

    public init() {}

    /// Injects the SwiftData model context. Call once from the view layer.
    public func configure(modelContext: ModelContext) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        loadSessions()
        Log.persistence.info("SessionManagerViewModel configured")
    }

    /// Creates a new session, inserts it, and returns it.
    @discardableResult
    public func createSession(title: String = "New Chat") -> ChatSession {
        let session = ChatSession(title: title)
        modelContext?.insert(session)
        save()
        loadSessions()
        return session
    }

    /// Deletes a session and all its messages.
    public func deleteSession(_ session: ChatSession) {
        guard let modelContext else { return }

        // Delete all messages belonging to this session
        let sessionID = session.id
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        if let messages = try? modelContext.fetch(descriptor) {
            for message in messages {
                modelContext.delete(message)
            }
        }

        modelContext.delete(session)
        save()

        // If the deleted session was active, clear selection
        if activeSession?.id == session.id {
            activeSession = nil
        }

        loadSessions()
    }

    /// Renames a session.
    public func renameSession(_ session: ChatSession, title: String) {
        session.title = title
        session.updatedAt = Date()
        save()
        loadSessions()
    }

    /// Auto-generates a session title from the first user message.
    /// Only applies if the current title is "New Chat".
    public func autoGenerateTitle(for session: ChatSession, firstMessage: String) {
        guard session.title == "New Chat" else { return }

        let maxLength = 50
        var title = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        if title.count > maxLength {
            // Truncate at word boundary
            let truncated = String(title.prefix(maxLength))
            if let lastSpace = truncated.lastIndex(of: " ") {
                title = String(truncated[truncated.startIndex..<lastSpace]) + "..."
            } else {
                title = truncated + "..."
            }
        }

        guard !title.isEmpty else { return }
        session.title = title
        session.updatedAt = Date()
        save()
        loadSessions()
    }

    /// Reloads sessions from SwiftData.
    public func loadSessions() {
        guard let modelContext else { return }

        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            sessions = try modelContext.fetch(descriptor)
        } catch {
            Log.persistence.error("Failed to load sessions: \(error)")
            sessions = []
        }
    }

    private func save() {
        guard let modelContext else { return }
        do {
            try modelContext.save()
        } catch {
            Log.persistence.error("Failed to save session: \(error)")
        }
    }
}

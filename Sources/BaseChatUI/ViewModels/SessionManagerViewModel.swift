import Foundation
import Observation
import BaseChatCore

/// Manages chat session CRUD operations and the session list.
@Observable
@MainActor
public final class SessionManagerViewModel {

    /// All sessions, sorted by most recently updated.
    public private(set) var sessions: [ChatSessionRecord] = []

    /// The currently active session.
    public var activeSession: ChatSessionRecord?

    private var persistence: ChatPersistenceProvider?

    public init() {}

    /// Injects the persistence provider. Call once from the view layer.
    public func configure(persistence: ChatPersistenceProvider) {
        guard self.persistence == nil else { return }
        self.persistence = persistence
        loadSessions()
        Log.persistence.info("SessionManagerViewModel configured")
    }

    /// Creates a new session, inserts it, and returns it.
    @discardableResult
    public func createSession(title: String = "New Chat") throws -> ChatSessionRecord {
        guard let persistence else {
            Log.persistence.warning("createSession called before persistence was configured")
            throw ChatPersistenceError.providerNotConfigured
        }
        let record = ChatSessionRecord(title: title)
        try persistence.insertSession(record)
        loadSessions()
        return record
    }

    /// Deletes a session and all its messages.
    public func deleteSession(_ session: ChatSessionRecord) {
        do {
            try persistence?.deleteSession(session.id)
        } catch {
            Log.persistence.error("Failed to delete session: \(error)")
        }

        if activeSession?.id == session.id {
            activeSession = nil
        }

        loadSessions()
    }

    /// Renames a session.
    public func renameSession(_ session: ChatSessionRecord, title: String) {
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try persistence?.updateSession(updated)
        } catch {
            Log.persistence.error("Failed to rename session: \(error)")
        }
        loadSessions()
    }

    // MARK: - AI Auto-Rename

    /// Generates a concise session title by running a short inference request.
    @MainActor
    public func generateTitle(
        from firstMessage: String,
        using inferenceService: InferenceService
    ) async -> String? {
        let systemPrompt = "Generate a concise 3-5 word title for a conversation that starts with the following message. Reply with ONLY the title, no punctuation, no quotes."
        let messages: [(role: String, content: String)] = [
            (role: "user", content: firstMessage)
        ]

        do {
            let stream = try inferenceService.generate(
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: 0.3,
                topP: 0.9,
                repeatPenalty: 1.0
            )
            var result = ""
            for try await event in stream.events {
                if case .token(let text) = event {
                    result += text
                }
            }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.count > 50 ? String(trimmed.prefix(50)) : trimmed
        } catch {
            Log.ui.debug("Title generation failed (ignored): \(error)")
            return nil
        }
    }

    /// Generates an AI title for the session and saves it.
    ///
    /// Only renames sessions that are still named "New Chat". Failures are
    /// silently ignored -- the session keeps its existing title.
    @MainActor
    public func autoRenameSession(
        _ session: ChatSessionRecord,
        firstMessage: String,
        inferenceService: InferenceService
    ) async {
        guard session.title == "New Chat" else { return }
        guard let title = await generateTitle(from: firstMessage, using: inferenceService) else { return }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try persistence?.updateSession(updated)
        } catch {
            Log.persistence.error("Failed to auto-rename session: \(error)")
        }
        loadSessions()
    }

    /// Auto-generates a session title from the first user message.
    /// Only applies if the current title is "New Chat".
    public func autoGenerateTitle(for session: ChatSessionRecord, firstMessage: String) {
        guard session.title == "New Chat" else { return }

        let maxLength = 50
        var title = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        if title.count > maxLength {
            let truncated = String(title.prefix(maxLength))
            if let lastSpace = truncated.lastIndex(of: " ") {
                title = String(truncated[truncated.startIndex..<lastSpace]) + "..."
            } else {
                title = truncated + "..."
            }
        }

        guard !title.isEmpty else { return }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try persistence?.updateSession(updated)
        } catch {
            Log.persistence.error("Failed to auto-generate title: \(error)")
        }
        loadSessions()
    }

    /// Reloads sessions from the persistence provider.
    public func loadSessions() {
        guard let persistence else { return }

        do {
            sessions = try persistence.fetchSessions()
        } catch {
            Log.persistence.error("Failed to load sessions: \(error)")
            sessions = []
        }
    }
}

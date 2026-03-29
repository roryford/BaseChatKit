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

    // MARK: - AI Auto-Rename

    /// Generates a concise session title by running a short inference request.
    ///
    /// Drains the token stream and returns the trimmed result, capped at 50
    /// characters. Returns `nil` on any error so callers can silently fall back.
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
            for try await token in stream {
                result += token
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
    /// silently ignored — the session keeps its existing title.
    @MainActor
    public func autoRenameSession(
        _ session: ChatSession,
        firstMessage: String,
        inferenceService: InferenceService
    ) async {
        guard session.title == "New Chat" else { return }
        guard let title = await generateTitle(from: firstMessage, using: inferenceService) else { return }
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

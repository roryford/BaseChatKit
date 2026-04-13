import Foundation
import Observation
import BaseChatCore
import BaseChatInference

/// Manages chat session CRUD operations and the session list.
@Observable
@MainActor
public final class SessionManagerViewModel {

    /// All sessions, sorted by most recently updated.
    public private(set) var sessions: [ChatSessionRecord] = []

    /// The currently active session.
    public var activeSession: ChatSessionRecord?

    private var persistence: ChatPersistenceProvider?

    /// Optional diagnostics sink for non-fatal operational failures
    /// (e.g., auto-rename inference errors). Inject via `configure` so
    /// existing call sites that do not care about diagnostics keep working.
    public private(set) var diagnostics: DiagnosticsService?

    public init() {}

    /// Injects the persistence provider. Call once from the view layer.
    public func configure(persistence: ChatPersistenceProvider, diagnostics: DiagnosticsService? = nil) {
        guard self.persistence == nil else { return }
        self.persistence = persistence
        self.diagnostics = diagnostics
        loadSessions()
        Log.persistence.info("SessionManagerViewModel configured")
    }

    /// Creates a new session, inserts it, activates it, and returns it.
    ///
    /// Setting `activeSession` to the new record ensures that
    /// `onChange(of: sessionManager.activeSession)` fires in the host view so
    /// `ChatViewModel.switchToSession(_:)` is called immediately. Without this,
    /// callers that rely on the binding (e.g. `SessionListView`'s `List(selection:)`)
    /// would leave the chat detail in a "No session selected" state until the user
    /// manually tapped a row.
    @discardableResult
    public func createSession(title: String = "New Chat") throws -> ChatSessionRecord {
        guard let persistence else {
            Log.persistence.warning("createSession called before persistence was configured")
            throw ChatPersistenceError.providerNotConfigured
        }
        let record = ChatSessionRecord(title: title)
        try persistence.insertSession(record)
        loadSessions()
        activeSession = record
        return record
    }

    /// Deletes a session and all its messages.
    public func deleteSession(_ session: ChatSessionRecord) throws {
        guard let persistence else {
            Log.persistence.warning("deleteSession called before persistence was configured")
            throw ChatPersistenceError.providerNotConfigured
        }
        try persistence.deleteSession(session.id)

        if activeSession?.id == session.id {
            activeSession = nil
        }

        loadSessions()
    }

    /// Renames a session.
    public func renameSession(_ session: ChatSessionRecord, title: String) throws {
        guard let persistence else {
            Log.persistence.warning("renameSession called before persistence was configured")
            throw ChatPersistenceError.providerNotConfigured
        }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        try persistence.updateSession(updated)
        loadSessions()
    }

    // MARK: - AI Auto-Rename

    /// Generates a concise session title by running a short inference request.
    ///
    /// Returns `nil` when the model produced an empty response. Throws the
    /// underlying inference error on failure so callers can surface it to
    /// `DiagnosticsService` instead of silently dropping it.
    @MainActor
    public func generateTitle(
        from firstMessage: String,
        using inferenceService: InferenceService
    ) async throws -> String? {
        let systemPrompt = "Generate a concise 3-5 word title for a conversation that starts with the following message. Reply with ONLY the title, no punctuation, no quotes."
        let messages: [(role: String, content: String)] = [
            (role: "user", content: firstMessage)
        ]

        let (_, stream) = try inferenceService.enqueue(
            messages: messages,
            systemPrompt: systemPrompt,
            temperature: 0.3,
            topP: 0.9,
            repeatPenalty: 1.0,
            priority: .background,
            sessionID: nil
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
    }

    /// Generates an AI title for the session and saves it.
    ///
    /// Only renames sessions that are still named "New Chat". Failures
    /// fall back to the existing title but are recorded on
    /// `DiagnosticsService` so they can be surfaced to the user.
    @MainActor
    public func autoRenameSession(
        _ session: ChatSessionRecord,
        firstMessage: String,
        inferenceService: InferenceService
    ) async {
        guard session.title == "New Chat" else { return }
        let title: String?
        do {
            title = try await generateTitle(from: firstMessage, using: inferenceService)
        } catch {
            Log.ui.warning("Title generation failed for session \(session.id): \(error.localizedDescription)")
            diagnostics?.record(.titleGenerationFailed(sessionID: session.id, reason: error.localizedDescription))
            return
        }
        guard let title else { return }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try persistence?.updateSession(updated)
        } catch {
            Log.persistence.warning("Failed to persist auto-rename for session \(session.id): \(error.localizedDescription)")
            // Persistence failure is a distinct category from inference
            // failure — different remediation (disk/store health vs.
            // backend availability), so we surface it as its own case.
            diagnostics?.record(.sessionRenamePersistenceFailed(sessionID: session.id, reason: error.localizedDescription))
            return
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

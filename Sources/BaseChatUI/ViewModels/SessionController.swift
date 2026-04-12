import Foundation
import Observation
import BaseChatCore

@Observable
@MainActor
final class SessionController {

    static let defaultTemperature: Float = 0.7
    static let defaultTopP: Float = 0.9
    static let defaultRepeatPenalty: Float = 1.1
    static let messagePageSize = 50

    struct SessionSelectionState {
        let selectedModelID: UUID?
        let selectedEndpointID: UUID?
    }

    var persistence: ChatPersistenceProvider?
    var activeSession: ChatSessionRecord?
    var messages: [ChatMessageRecord] = []
    var systemPrompt: String = ""
    var temperature: Float = defaultTemperature
    var topP: Float = defaultTopP
    var repeatPenalty: Float = defaultRepeatPenalty
    var selectedPromptTemplate: PromptTemplate
    let defaultPromptTemplate: PromptTemplate
    var pinnedMessageIDs: Set<UUID> = []
    var hasOlderMessages: Bool = false
    var isLoadingOlderMessages: Bool = false

    init(selectedPromptTemplate: PromptTemplate = .chatML) {
        self.selectedPromptTemplate = selectedPromptTemplate
        self.defaultPromptTemplate = selectedPromptTemplate
    }

    var activeSessionID: UUID? {
        activeSession?.id
    }

    func configure(persistence: ChatPersistenceProvider) {
        guard self.persistence == nil else { return }
        self.persistence = persistence
        Log.persistence.info("ChatViewModel configured with persistence provider")
    }

    @discardableResult
    func activateSession(_ session: ChatSessionRecord) -> SessionSelectionState {
        activeSession = session
        systemPrompt = session.systemPrompt
        temperature = session.temperature ?? Self.defaultTemperature
        topP = session.topP ?? Self.defaultTopP
        repeatPenalty = session.repeatPenalty ?? Self.defaultRepeatPenalty
        selectedPromptTemplate = session.promptTemplate ?? defaultPromptTemplate
        pinnedMessageIDs = session.pinnedMessageIDs
        return SessionSelectionState(
            selectedModelID: session.selectedModelID,
            selectedEndpointID: session.selectedEndpointID
        )
    }

    func touchActiveSessionUpdatedAt(_ date: Date = Date()) throws {
        guard var session = activeSession else { return }

        session.updatedAt = date
        activeSession = session

        guard let persistence else {
            Log.persistence.warning("touchActiveSessionUpdatedAt called before persistence was configured")
            return
        }

        do {
            try persistence.updateSession(session)
        } catch ChatPersistenceError.sessionNotFound {
            Log.persistence.warning(
                "Active session was not yet persisted when updating session timestamp: \(session.id, privacy: .private)"
            )
        }
    }

    func saveSettingsToSession(
        selectedModelID: UUID?,
        selectedEndpointID: UUID?
    ) throws {
        guard var session = activeSession else { return }
        guard let persistence else {
            Log.persistence.warning("saveSettingsToSession called before persistence was configured")
            throw ChatPersistenceError.providerNotConfigured
        }
        session.temperature = temperature
        session.topP = topP
        session.repeatPenalty = repeatPenalty
        session.systemPrompt = systemPrompt
        session.selectedModelID = selectedModelID
        session.selectedEndpointID = selectedEndpointID
        session.promptTemplate = selectedPromptTemplate
        session.pinnedMessageIDs = pinnedMessageIDs
        session.updatedAt = Date()
        try persistence.updateSession(session)
        activeSession = session
    }

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
            hasOlderMessages = page.count >= Self.messagePageSize
            Log.persistence.info("Loaded \(page.count) messages (hasOlder: \(self.hasOlderMessages))")
        } catch {
            Log.persistence.error("Failed to load messages: \(error)")
            messages = []
            hasOlderMessages = false
        }
    }

    @discardableResult
    func loadOlderMessages() -> UUID? {
        guard !isLoadingOlderMessages, hasOlderMessages else { return nil }
        guard let persistence else { return nil }
        guard let sessionID = activeSessionID else { return nil }
        guard let oldestTimestamp = messages.first?.timestamp else { return nil }

        let anchorID = messages.first?.id
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        do {
            let older = try persistence.fetchMessages(
                for: sessionID,
                before: oldestTimestamp,
                limit: Self.messagePageSize
            )
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

    func saveMessage(_ message: ChatMessageRecord) throws {
        guard let persistence else {
            Log.persistence.warning("saveMessage called before persistence was configured — message will not be persisted")
            return
        }
        do {
            try persistence.updateMessage(message)
        } catch ChatPersistenceError.messageNotFound {
            try persistence.insertMessage(message)
        }
    }

    func updateMessage(_ message: ChatMessageRecord) throws {
        guard let persistence else {
            Log.persistence.warning("updateMessage called before persistence was configured — message will not be updated")
            return
        }
        try persistence.updateMessage(message)
    }

    func deleteMessage(_ message: ChatMessageRecord) throws {
        guard let persistence else {
            Log.persistence.warning("deleteMessage called before persistence was configured — message will not be deleted")
            return
        }
        try persistence.deleteMessage(message.id)
    }

    func deleteMessages(for sessionID: UUID) throws {
        guard let persistence else {
            Log.persistence.warning("deleteMessages called before persistence was configured — messages will not be deleted")
            return
        }
        try persistence.deleteMessages(for: sessionID)
    }
}

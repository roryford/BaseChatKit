import Foundation
import BaseChatCore
import BaseChatInference

/// In-memory mock of ``ChatPersistenceProvider`` for testing.
///
/// Stores sessions and messages in plain arrays. Thread-safe via `@MainActor`.
@MainActor
public final class MockPersistenceProvider: ChatPersistenceProvider {

    public var sessions: [ChatSessionRecord] = []
    public var messages: [ChatMessageRecord] = []

    // Call tracking
    public var insertSessionCallCount = 0
    public var updateSessionCallCount = 0
    public var deleteSessionCallCount = 0
    public var fetchSessionsCallCount = 0
    public var insertMessageCallCount = 0
    public var updateMessageCallCount = 0
    public var deleteMessageCallCount = 0
    public var deleteMessagesCallCount = 0
    public var fetchMessagesCallCount = 0

    public var shouldThrowOnInsertSession: Error?
    public var shouldThrowOnUpdateSession: Error?
    public var shouldThrowOnFetchSessions: Error?
    public var shouldThrowOnInsertMessage: Error?
    public var shouldThrowOnFetchMessages: Error?
    public var shouldThrowOnDeleteMessages: Error?
    public var fetchRecentMessagesCallCount = 0
    public var fetchMessagesBeforeCallCount = 0

    public init() {}

    // MARK: - Sessions

    public func insertSession(_ session: ChatSessionRecord) throws {
        insertSessionCallCount += 1
        if let error = shouldThrowOnInsertSession { throw error }
        sessions.append(session)
    }

    public func updateSession(_ session: ChatSessionRecord) throws {
        updateSessionCallCount += 1
        if let error = shouldThrowOnUpdateSession { throw error }
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else {
            throw ChatPersistenceError.sessionNotFound(session.id)
        }
        sessions[idx] = session
    }

    public func deleteSession(_ sessionID: UUID) throws {
        deleteSessionCallCount += 1
        guard sessions.contains(where: { $0.id == sessionID }) else {
            throw ChatPersistenceError.sessionNotFound(sessionID)
        }
        try deleteMessages(for: sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    public func fetchSessions() throws -> [ChatSessionRecord] {
        fetchSessionsCallCount += 1
        if let error = shouldThrowOnFetchSessions { throw error }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Messages

    public func insertMessage(_ message: ChatMessageRecord) throws {
        insertMessageCallCount += 1
        if let error = shouldThrowOnInsertMessage { throw error }
        messages.append(message)
    }

    public func updateMessage(_ message: ChatMessageRecord) throws {
        updateMessageCallCount += 1
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else {
            throw ChatPersistenceError.messageNotFound(message.id)
        }
        messages[idx] = message
    }

    public func deleteMessage(_ messageID: UUID) throws {
        deleteMessageCallCount += 1
        guard messages.contains(where: { $0.id == messageID }) else {
            throw ChatPersistenceError.messageNotFound(messageID)
        }
        messages.removeAll { $0.id == messageID }
    }

    public func fetchMessages(for sessionID: UUID) throws -> [ChatMessageRecord] {
        fetchMessagesCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        return messages
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func fetchRecentMessages(for sessionID: UUID, limit: Int) throws -> [ChatMessageRecord] {
        fetchRecentMessagesCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        let sorted = messages
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
        return Array(sorted.suffix(limit))
    }

    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) throws -> [ChatMessageRecord] {
        fetchMessagesBeforeCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        let older = messages
            .filter { $0.sessionID == sessionID && $0.timestamp < before }
            .sorted { $0.timestamp < $1.timestamp }
        return Array(older.suffix(limit))
    }

    public func deleteMessages(for sessionID: UUID) throws {
        deleteMessagesCallCount += 1
        if let error = shouldThrowOnDeleteMessages { throw error }
        messages.removeAll { $0.sessionID == sessionID }
    }
}

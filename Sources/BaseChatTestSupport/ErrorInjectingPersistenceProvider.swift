import Foundation
import BaseChatCore
import BaseChatInference

/// Test double that wraps any ``ChatPersistenceProvider`` and adds two
/// facilities the real provider cannot offer: per-method error injection
/// and call counting.
///
/// Pair it with ``InMemoryPersistenceHarness`` when a test needs to assert
/// that a view model handles persistence failures correctly, or that it
/// routed through the persistence layer the expected number of times.
/// All other persistence behaviour (CRUD, ordering, pagination) is the
/// real provider's, so tests written against this wrapper stay honest.
@MainActor
public final class ErrorInjectingPersistenceProvider: ChatPersistenceProvider {

    private let wrapped: any ChatPersistenceProvider

    public var shouldThrowOnInsertSession: Error?
    public var shouldThrowOnUpdateSession: Error?
    public var shouldThrowOnFetchSessions: Error?
    public var shouldThrowOnInsertMessage: Error?
    public var shouldThrowOnFetchMessages: Error?
    public var shouldThrowOnDeleteMessages: Error?

    public var insertSessionCallCount = 0
    public var updateSessionCallCount = 0
    public var deleteSessionCallCount = 0
    public var fetchSessionsCallCount = 0
    public var insertMessageCallCount = 0
    public var updateMessageCallCount = 0
    public var deleteMessageCallCount = 0
    public var fetchMessagesCallCount = 0
    public var fetchRecentMessagesCallCount = 0
    public var fetchMessagesBeforeCallCount = 0
    public var deleteMessagesCallCount = 0

    public init(wrapping wrapped: any ChatPersistenceProvider) {
        self.wrapped = wrapped
    }

    public func insertSession(_ session: ChatSessionRecord) throws {
        insertSessionCallCount += 1
        if let error = shouldThrowOnInsertSession { throw error }
        try wrapped.insertSession(session)
    }

    public func updateSession(_ session: ChatSessionRecord) throws {
        updateSessionCallCount += 1
        if let error = shouldThrowOnUpdateSession { throw error }
        try wrapped.updateSession(session)
    }

    public func deleteSession(_ sessionID: UUID) throws {
        deleteSessionCallCount += 1
        try wrapped.deleteSession(sessionID)
    }

    public func fetchSessions() throws -> [ChatSessionRecord] {
        fetchSessionsCallCount += 1
        if let error = shouldThrowOnFetchSessions { throw error }
        return try wrapped.fetchSessions()
    }

    public func insertMessage(_ message: ChatMessageRecord) throws {
        insertMessageCallCount += 1
        if let error = shouldThrowOnInsertMessage { throw error }
        try wrapped.insertMessage(message)
    }

    public func updateMessage(_ message: ChatMessageRecord) throws {
        updateMessageCallCount += 1
        try wrapped.updateMessage(message)
    }

    public func deleteMessage(_ messageID: UUID) throws {
        deleteMessageCallCount += 1
        try wrapped.deleteMessage(messageID)
    }

    public func fetchMessages(for sessionID: UUID) throws -> [ChatMessageRecord] {
        fetchMessagesCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        return try wrapped.fetchMessages(for: sessionID)
    }

    public func fetchRecentMessages(for sessionID: UUID, limit: Int) throws -> [ChatMessageRecord] {
        fetchRecentMessagesCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        return try wrapped.fetchRecentMessages(for: sessionID, limit: limit)
    }

    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) throws -> [ChatMessageRecord] {
        fetchMessagesBeforeCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        return try wrapped.fetchMessages(for: sessionID, before: before, limit: limit)
    }

    public func deleteMessages(for sessionID: UUID) throws {
        deleteMessagesCallCount += 1
        if let error = shouldThrowOnDeleteMessages { throw error }
        try wrapped.deleteMessages(for: sessionID)
    }
}

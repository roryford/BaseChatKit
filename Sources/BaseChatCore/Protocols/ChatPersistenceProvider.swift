import Foundation
import BaseChatInference

/// Errors produced by ``ChatPersistenceProvider`` implementations.
public enum ChatPersistenceError: Error, LocalizedError, Sendable, Equatable {
    case providerNotConfigured
    case sessionNotFound(UUID)
    case messageNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            return "Persistence provider is not configured."
        case let .sessionNotFound(sessionID):
            return "Session not found: \(sessionID.uuidString)"
        case let .messageNotFound(messageID):
            return "Message not found: \(messageID.uuidString)"
        }
    }
}

/// Abstraction over chat persistence, decoupling view models from SwiftData.
///
/// The default implementation is ``SwiftDataPersistenceProvider``. Tests can
/// substitute ``MockPersistenceProvider`` from `BaseChatTestSupport`.
@MainActor
public protocol ChatPersistenceProvider: AnyObject, Sendable {

    // MARK: - Sessions

    /// Inserts a new chat session.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func insertSession(_ session: ChatSessionRecord) throws

    /// Updates an existing chat session.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/sessionNotFound(_:)`` when the session does not exist.
    ///   - Storage errors from the underlying provider.
    func updateSession(_ session: ChatSessionRecord) throws

    /// Deletes a chat session and all associated messages.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/sessionNotFound(_:)`` when the session does not exist.
    ///   - Storage errors from the underlying provider.
    func deleteSession(_ sessionID: UUID) throws

    /// Fetches all chat sessions sorted by most-recently-updated.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func fetchSessions() throws -> [ChatSessionRecord]

    // MARK: - Messages

    /// Inserts a new chat message.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func insertMessage(_ message: ChatMessageRecord) throws

    /// Updates an existing chat message.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/messageNotFound(_:)`` when the message does not exist.
    ///   - Storage errors from the underlying provider.
    func updateMessage(_ message: ChatMessageRecord) throws

    /// Deletes a chat message.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/messageNotFound(_:)`` when the message does not exist.
    ///   - Storage errors from the underlying provider.
    func deleteMessage(_ messageID: UUID) throws

    /// Fetches messages for a session in timestamp order.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func fetchMessages(for sessionID: UUID) throws -> [ChatMessageRecord]

    /// Fetches the most recent messages for a session, up to `limit`.
    ///
    /// Results are returned in ascending timestamp order (oldest first).
    /// Use ``fetchMessages(for:before:limit:)`` to page backwards from a known timestamp.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func fetchRecentMessages(for sessionID: UUID, limit: Int) throws -> [ChatMessageRecord]

    /// Fetches messages older than `before` for a session, up to `limit`.
    ///
    /// Results are returned in ascending timestamp order (oldest first).
    /// Returns an empty array when no older messages exist.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func fetchMessages(for sessionID: UUID, before: Date, limit: Int) throws -> [ChatMessageRecord]

    /// Deletes all messages for a session.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func deleteMessages(for sessionID: UUID) throws
}

// MARK: - Default pagination implementations

extension ChatPersistenceProvider {

    /// Default: fetches all messages then returns the last `limit`.
    public func fetchRecentMessages(for sessionID: UUID, limit: Int) throws -> [ChatMessageRecord] {
        let all = try fetchMessages(for: sessionID)
        return Array(all.suffix(limit))
    }

    /// Default: fetches all messages then filters to those before `before`.
    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) throws -> [ChatMessageRecord] {
        let all = try fetchMessages(for: sessionID)
        let older = all.filter { $0.timestamp < before }
        return Array(older.suffix(limit))
    }
}

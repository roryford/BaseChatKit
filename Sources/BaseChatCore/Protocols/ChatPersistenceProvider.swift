import Foundation

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

/// Plain-data snapshot of a ``ChatSession`` for use across persistence boundaries.
///
/// Decouples view models from SwiftData so callers can swap in any storage backend.
public struct ChatSessionRecord: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var systemPrompt: String
    public var selectedModelID: UUID?
    public var selectedEndpointID: UUID?
    public var temperature: Float?
    public var topP: Float?
    public var repeatPenalty: Float?
    public var promptTemplateRawValue: String?
    public var contextSizeOverride: Int?
    public var compressionModeRaw: String?
    public var pinnedMessageIDsRaw: String?

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        systemPrompt: String = "",
        selectedModelID: UUID? = nil,
        selectedEndpointID: UUID? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        repeatPenalty: Float? = nil,
        promptTemplateRawValue: String? = nil,
        contextSizeOverride: Int? = nil,
        compressionModeRaw: String? = nil,
        pinnedMessageIDsRaw: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.systemPrompt = systemPrompt
        self.selectedModelID = selectedModelID
        self.selectedEndpointID = selectedEndpointID
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.promptTemplateRawValue = promptTemplateRawValue
        self.contextSizeOverride = contextSizeOverride
        self.compressionModeRaw = compressionModeRaw
        self.pinnedMessageIDsRaw = pinnedMessageIDsRaw
    }

    public var pinnedMessageIDs: Set<UUID> {
        get {
            guard let raw = pinnedMessageIDsRaw else { return [] }
            return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }
        set {
            pinnedMessageIDsRaw = newValue.isEmpty ? nil : newValue.map(\.uuidString).joined(separator: ",")
        }
    }

    public var compressionMode: CompressionMode {
        get { compressionModeRaw.flatMap(CompressionMode.init(rawValue:)) ?? .automatic }
        set { compressionModeRaw = newValue.rawValue }
    }

    public var promptTemplate: PromptTemplate? {
        get {
            guard let raw = promptTemplateRawValue else { return nil }
            return PromptTemplate(rawValue: raw)
        }
        set {
            promptTemplateRawValue = newValue?.rawValue
        }
    }
}

/// Plain-data snapshot of a ``ChatMessage`` for use across persistence boundaries.
public struct ChatMessageRecord: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var contentParts: [MessagePart]
    public var timestamp: Date
    public var sessionID: UUID
    public var promptTokens: Int?
    public var completionTokens: Int?

    /// Concatenated text parts for backward compatibility.
    ///
    /// Setting this replaces the entire `contentParts` array with a single `.text` part.
    public var content: String {
        get { contentParts.compactMap(\.textContent).joined() }
        set { contentParts = [.text(newValue)] }
    }

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        sessionID: UUID,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.contentParts = [.text(content)]
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    /// Creates a record from structured content parts.
    public init(
        id: UUID = UUID(),
        role: MessageRole,
        contentParts: [MessagePart],
        timestamp: Date = Date(),
        sessionID: UUID,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.contentParts = contentParts
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
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

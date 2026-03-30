import Foundation

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
    public var content: String
    public var timestamp: Date
    public var sessionID: UUID
    public var promptTokens: Int?
    public var completionTokens: Int?

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
        self.content = content
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
public protocol ChatPersistenceProvider: AnyObject, Sendable {

    // MARK: - Sessions

    func insertSession(_ session: ChatSessionRecord) throws
    func updateSession(_ session: ChatSessionRecord) throws
    func deleteSession(_ sessionID: UUID) throws
    func fetchSessions() throws -> [ChatSessionRecord]

    // MARK: - Messages

    func insertMessage(_ message: ChatMessageRecord) throws
    func updateMessage(_ message: ChatMessageRecord) throws
    func deleteMessage(_ messageID: UUID) throws
    func fetchMessages(for sessionID: UUID) throws -> [ChatMessageRecord]
    func deleteMessages(for sessionID: UUID) throws
}

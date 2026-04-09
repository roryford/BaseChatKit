import Foundation
import SwiftData

/// Default ``ChatPersistenceProvider`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, converting between
/// SwiftData `@Model` objects and plain ``ChatSessionRecord`` / ``ChatMessageRecord``
/// value types at the boundary.
@MainActor
public final class SwiftDataPersistenceProvider: ChatPersistenceProvider {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Sessions

    public func insertSession(_ record: ChatSessionRecord) throws {
        let session = ChatSession(title: record.title)
        session.id = record.id
        session.createdAt = record.createdAt
        session.updatedAt = record.updatedAt
        session.systemPrompt = record.systemPrompt
        session.selectedModelID = record.selectedModelID
        session.selectedEndpointID = record.selectedEndpointID
        session.temperature = record.temperature
        session.topP = record.topP
        session.repeatPenalty = record.repeatPenalty
        session.promptTemplateRawValue = record.promptTemplate?.rawValue
        session.contextSizeOverride = record.contextSizeOverride
        session.compressionModeRaw = record.compressionMode == .automatic ? nil : record.compressionMode.rawValue
        session.pinnedMessageIDsRaw = record.pinnedMessageIDs.isEmpty ? nil : record.pinnedMessageIDs.map(\.uuidString).joined(separator: ",")
        modelContext.insert(session)
        try modelContext.save()
    }

    public func updateSession(_ record: ChatSessionRecord) throws {
        guard let session = try fetchSwiftDataSession(id: record.id) else {
            throw ChatPersistenceError.sessionNotFound(record.id)
        }
        session.title = record.title
        session.updatedAt = record.updatedAt
        session.systemPrompt = record.systemPrompt
        session.selectedModelID = record.selectedModelID
        session.selectedEndpointID = record.selectedEndpointID
        session.temperature = record.temperature
        session.topP = record.topP
        session.repeatPenalty = record.repeatPenalty
        session.promptTemplateRawValue = record.promptTemplate?.rawValue
        session.contextSizeOverride = record.contextSizeOverride
        session.compressionModeRaw = record.compressionMode == .automatic ? nil : record.compressionMode.rawValue
        session.pinnedMessageIDsRaw = record.pinnedMessageIDs.isEmpty ? nil : record.pinnedMessageIDs.map(\.uuidString).joined(separator: ",")
        try modelContext.save()
    }

    public func deleteSession(_ sessionID: UUID) throws {
        guard let session = try fetchSwiftDataSession(id: sessionID) else {
            throw ChatPersistenceError.sessionNotFound(sessionID)
        }
        try deleteMessages(for: sessionID)
        modelContext.delete(session)
        try modelContext.save()
    }

    public func fetchSessions() throws -> [ChatSessionRecord] {
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    // MARK: - Messages

    public func insertMessage(_ record: ChatMessageRecord) throws {
        let message = ChatMessage(role: record.role, contentParts: record.contentParts, sessionID: record.sessionID)
        message.id = record.id
        message.timestamp = record.timestamp
        message.promptTokens = record.promptTokens
        message.completionTokens = record.completionTokens
        modelContext.insert(message)
        try modelContext.save()
    }

    public func updateMessage(_ record: ChatMessageRecord) throws {
        guard let message = try fetchSwiftDataMessage(id: record.id) else {
            throw ChatPersistenceError.messageNotFound(record.id)
        }
        message.contentParts = record.contentParts
        message.promptTokens = record.promptTokens
        message.completionTokens = record.completionTokens
        try modelContext.save()
    }

    public func deleteMessage(_ messageID: UUID) throws {
        guard let message = try fetchSwiftDataMessage(id: messageID) else {
            throw ChatPersistenceError.messageNotFound(messageID)
        }
        modelContext.delete(message)
        try modelContext.save()
    }

    public func fetchMessages(for sessionID: UUID) throws -> [ChatMessageRecord] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    public func fetchRecentMessages(for sessionID: UUID, limit: Int) throws -> [ChatMessageRecord] {
        // Fetch newest-first, take `limit`, then reverse to ascending order.
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let results = try modelContext.fetch(descriptor)
        return results.reversed().map { $0.toRecord() }
    }

    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) throws -> [ChatMessageRecord] {
        // Fetch messages older than `before`, newest-first, take `limit`, then reverse.
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.timestamp < before },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let results = try modelContext.fetch(descriptor)
        return results.reversed().map { $0.toRecord() }
    }

    public func deleteMessages(for sessionID: UUID) throws {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for message in try modelContext.fetch(descriptor) {
            modelContext.delete(message)
        }
        try modelContext.save()
    }

    // MARK: - Private

    private func fetchSwiftDataSession(id: UUID) throws -> ChatSession? {
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchSwiftDataMessage(id: UUID) throws -> ChatMessage? {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }
}

// MARK: - Model <-> Record conversions

extension ChatSession {
    /// Converts a SwiftData model to a plain record.
    func toRecord() -> ChatSessionRecord {
        ChatSessionRecord(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            systemPrompt: systemPrompt,
            selectedModelID: selectedModelID,
            selectedEndpointID: selectedEndpointID,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            promptTemplate: promptTemplateRawValue.flatMap(PromptTemplate.init(rawValue:)),
            contextSizeOverride: contextSizeOverride,
            compressionMode: compressionModeRaw.flatMap(CompressionMode.init(rawValue:)) ?? .automatic,
            pinnedMessageIDs: Set(pinnedMessageIDsRaw?.split(separator: ",").compactMap { UUID(uuidString: String($0)) } ?? [])
        )
    }
}

extension ChatMessage {
    /// Converts a SwiftData model to a plain record.
    func toRecord() -> ChatMessageRecord {
        ChatMessageRecord(
            id: id,
            role: role,
            contentParts: contentParts,
            timestamp: timestamp,
            sessionID: sessionID,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }
}

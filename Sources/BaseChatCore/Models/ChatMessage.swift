/// The role of a participant in a chat conversation.
public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// Public alias for the V1 SwiftData chat message model.
public typealias ChatMessage = BaseChatSchemaV1.ChatMessage

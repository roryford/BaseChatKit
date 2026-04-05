import Foundation
import SwiftData

/// The role of a participant in a chat conversation.
public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// A single message in a chat conversation, persisted via SwiftData.
///
/// The concrete type is the frozen snapshot defined in `BaseChatSchemaV1`.
/// Update this typealias when a new schema version changes this model.
public typealias ChatMessage = BaseChatSchemaV1.ChatMessage

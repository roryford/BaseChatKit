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
/// Messages belong to a session (identified by `sessionID`).
@Model
public final class ChatMessage {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var timestamp: Date
    public var sessionID: UUID

    /// Tokens used in the prompt for this response (cloud API backends only).
    public var promptTokens: Int?
    /// Tokens generated in this response (cloud API backends only).
    public var completionTokens: Int?

    public init(
        role: MessageRole,
        content: String,
        sessionID: UUID
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.sessionID = sessionID
    }
}

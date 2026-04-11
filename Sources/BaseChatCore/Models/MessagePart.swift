import Foundation

/// A discrete piece of content within a chat message.
///
/// Messages can contain multiple parts to support multimodal input (images)
/// alongside plain text. Each part is independently typed so the UI can
/// render appropriate controls (e.g., inline images) and backends can map
/// parts to their native message formats.
///
/// `ChatMessage.decode` falls back to a `.text` part when JSON decoding
/// fails, so any pre-removal persisted rows containing `toolCall` /
/// `toolResult` discriminators degrade gracefully to a text bubble rather
/// than crashing.
public enum MessagePart: Codable, Hashable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)
}

extension MessagePart {

    /// The plain-text content of this part, or `nil` for non-text parts.
    public var textContent: String? {
        if case .text(let t) = self { return t }
        return nil
    }
}

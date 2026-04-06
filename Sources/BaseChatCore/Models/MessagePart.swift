import Foundation

/// A discrete piece of content within a chat message.
///
/// Messages can contain multiple parts to support multimodal input (images),
/// tool calling, and tool results alongside plain text. Each part is
/// independently typed so the UI can render appropriate controls (e.g.,
/// inline images, collapsible tool call blocks) and backends can map parts
/// to their native message formats.
public enum MessagePart: Codable, Hashable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)
    case toolCall(id: String, name: String, arguments: String)
    case toolResult(id: String, content: String)
}

extension MessagePart {

    /// The plain-text content of this part, or `nil` for non-text parts.
    public var textContent: String? {
        if case .text(let t) = self { return t }
        return nil
    }
}

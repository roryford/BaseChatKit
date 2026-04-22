import Foundation

/// A discrete piece of content within a chat message.
///
/// Messages can contain multiple parts to support multimodal input (images)
/// alongside plain text, model reasoning (``thinking``), and tool calling
/// (``toolCall`` / ``toolResult``). Each part is independently typed so the
/// UI can render appropriate controls (e.g., inline images, collapsible
/// reasoning blocks) and backends can map parts to their native message
/// formats.
///
/// ## Persistence compatibility
///
/// ``BaseChatSchemaV3/ChatMessage/decode(_:)`` falls back to a `.text` part
/// when JSON decoding fails. Historically this meant pre-removal rows that
/// contained ``toolCall`` / ``toolResult`` discriminators degraded gracefully
/// to text bubbles.  Those discriminators are now first-class cases again
/// (see ``BaseChatSchemaV4``), so such rows decode correctly as their actual
/// cases. The `.text` fallback remains as a safety net for genuinely
/// malformed JSON until V5.
public enum MessagePart: Codable, Hashable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)
    /// Accumulated model reasoning. Excluded from context window (textContent returns nil).
    case thinking(String)
    /// A tool invocation emitted by the model during generation.
    ///
    /// Persisted so that the conversation history preserves the full
    /// tool-calling turn (model asks → host executes → model continues).
    /// Excluded from ``textContent`` and from the accessibility label.
    case toolCall(ToolCall)
    /// The outcome of executing a ``ToolCall``, fed back into the conversation.
    ///
    /// Excluded from ``textContent`` and from the accessibility label.
    case toolResult(ToolResult)

    // Pin the on-disk discriminator keys. Swift's synthesized Codable uses the
    // case name by default; declaring CodingKeys explicitly makes the wire
    // contract load-bearing and visible to reviewers. Renaming one of these
    // raw values would silently strand every persisted row, so the
    // `test_toolCall_codableRoundtrip` wire-format assertion in
    // MessagePartToolCasesTests is the sentry that catches such drift.
    private enum CodingKeys: String, CodingKey {
        case text, image, thinking, toolCall, toolResult
    }
}

extension MessagePart {

    /// The plain-text content of this part, or `nil` for non-text parts.
    public var textContent: String? {
        if case .text(let t) = self { return t }
        return nil
    }

    public var thinkingContent: String? {
        if case .thinking(let t) = self { return t }
        return nil
    }

    /// The ``ToolCall`` payload of this part, or `nil` for non-tool-call parts.
    public var toolCallContent: ToolCall? {
        if case .toolCall(let c) = self { return c }
        return nil
    }

    /// The ``ToolResult`` payload of this part, or `nil` for non-tool-result parts.
    public var toolResultContent: ToolResult? {
        if case .toolResult(let r) = self { return r }
        return nil
    }
}

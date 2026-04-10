import Foundation

/// Lifecycle state of a tool call persisted inside a message bubble.
///
/// Stored alongside the ``MessagePart/toolCall(id:name:arguments:state:)``
/// payload so history reloads can faithfully render whether a tool call is
/// still waiting, was run, was rejected, or had its arguments edited before
/// execution.
public enum ToolCallApprovalState: String, Codable, Hashable, Sendable {

    /// The model requested this call but the user has not yet decided.
    case pending

    /// The call ran (either auto-approved or explicitly approved).
    case approved

    /// The user approved execution after editing the arguments.
    case edited

    /// The user explicitly rejected the call. A synthetic rejection result
    /// was fed back to the model.
    case rejected
}

/// A discrete piece of content within a chat message.
///
/// Messages can contain multiple parts to support multimodal input (images),
/// tool calling, and tool results alongside plain text. Each part is
/// independently typed so the UI can render appropriate controls (e.g.,
/// inline images, collapsible tool call blocks) and backends can map parts
/// to their native message formats.
public enum MessagePart: Hashable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)

    /// A tool invocation. `state` defaults to `.approved` to keep sources
    /// that do not pass the argument compiling, and to match the
    /// pre-approval-gate historical behaviour where every tool call that
    /// landed in history had already executed.
    case toolCall(id: String, name: String, arguments: String, state: ToolCallApprovalState = .approved)

    case toolResult(id: String, content: String)
}

extension MessagePart {

    /// The plain-text content of this part, or `nil` for non-text parts.
    public var textContent: String? {
        if case .text(let t) = self { return t }
        return nil
    }
}

// MARK: - Codable

/// Custom Codable matches Swift's synthesised enum format so persisted
/// history from before the approval feature still decodes. Adding
/// ``ToolCallApprovalState`` to `.toolCall` via default parameter is source-
/// compatible for callers, but the default synthesised decoder would reject
/// old rows that lack the `state` key — so we decode it as optional and
/// fall back to ``ToolCallApprovalState/approved``, which matches the
/// semantics of pre-existing rows (they ran silently).
extension MessagePart: Codable {

    private enum RootKey: String, CodingKey {
        case text
        case image
        case toolCall
        case toolResult
    }

    private enum TextKey: String, CodingKey {
        case _0
    }

    private enum ImageKey: String, CodingKey {
        case data
        case mimeType
    }

    private enum ToolCallKey: String, CodingKey {
        case id
        case name
        case arguments
        case state
    }

    private enum ToolResultKey: String, CodingKey {
        case id
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RootKey.self)
        if let textContainer = try? container.nestedContainer(keyedBy: TextKey.self, forKey: .text) {
            self = .text(try textContainer.decode(String.self, forKey: ._0))
            return
        }
        if let imageContainer = try? container.nestedContainer(keyedBy: ImageKey.self, forKey: .image) {
            let data = try imageContainer.decode(Data.self, forKey: .data)
            let mimeType = try imageContainer.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
            return
        }
        if let toolCallContainer = try? container.nestedContainer(keyedBy: ToolCallKey.self, forKey: .toolCall) {
            let id = try toolCallContainer.decode(String.self, forKey: .id)
            let name = try toolCallContainer.decode(String.self, forKey: .name)
            let arguments = try toolCallContainer.decode(String.self, forKey: .arguments)
            let state = try toolCallContainer.decodeIfPresent(ToolCallApprovalState.self, forKey: .state) ?? .approved
            self = .toolCall(id: id, name: name, arguments: arguments, state: state)
            return
        }
        if let toolResultContainer = try? container.nestedContainer(keyedBy: ToolResultKey.self, forKey: .toolResult) {
            let id = try toolResultContainer.decode(String.self, forKey: .id)
            let content = try toolResultContainer.decode(String.self, forKey: .content)
            self = .toolResult(id: id, content: content)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "No recognised MessagePart case found in payload"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RootKey.self)
        switch self {
        case .text(let text):
            var nested = container.nestedContainer(keyedBy: TextKey.self, forKey: .text)
            try nested.encode(text, forKey: ._0)
        case .image(let data, let mimeType):
            var nested = container.nestedContainer(keyedBy: ImageKey.self, forKey: .image)
            try nested.encode(data, forKey: .data)
            try nested.encode(mimeType, forKey: .mimeType)
        case .toolCall(let id, let name, let arguments, let state):
            var nested = container.nestedContainer(keyedBy: ToolCallKey.self, forKey: .toolCall)
            try nested.encode(id, forKey: .id)
            try nested.encode(name, forKey: .name)
            try nested.encode(arguments, forKey: .arguments)
            try nested.encode(state, forKey: .state)
        case .toolResult(let id, let content):
            var nested = container.nestedContainer(keyedBy: ToolResultKey.self, forKey: .toolResult)
            try nested.encode(id, forKey: .id)
            try nested.encode(content, forKey: .content)
        }
    }
}

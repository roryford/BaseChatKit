import Foundation
import SwiftData

/// Version 2 of the BaseChatKit SwiftData schema.
///
/// Adds `contentPartsJSON` to ``ChatMessage`` to support structured multimodal
/// content (text, images, tool calls, tool results). The legacy `content` column
/// is retained as a persisted property, kept in sync with `contentPartsJSON`,
/// so that SwiftData preserves its value through migration and it can serve as
/// a fast-path accessor for text-only messages.
///
/// ## Migration from V1
///
/// A custom migration stage wraps each existing `content` string into a
/// `[MessagePart.text(content)]` JSON array and stores it in `contentPartsJSON`.
public enum BaseChatSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ChatMessage.self,
            ChatSession.self,
            SamplerPreset.self,
            APIEndpoint.self,
        ]
    }

    // MARK: - ChatMessage (V2)

    /// A single message in a chat conversation, persisted via SwiftData.
    ///
    /// Content is stored as a JSON-encoded `[MessagePart]` array in
    /// `contentPartsJSON`. The `content` property concatenates text parts
    /// for backward compatibility.
    @Model
    public final class ChatMessage {
        public var id: UUID
        public var role: MessageRole
        public var timestamp: Date
        public var sessionID: UUID

        /// Retained from V1 so SwiftData preserves the column during migration.
        /// After migration, kept in sync as a denormalised cache of text content.
        public var content: String

        /// JSON-encoded `[MessagePart]` array. This is the source of truth for
        /// structured content. Empty string means "use `content` as a single text part".
        public var contentPartsJSON: String

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
            self.timestamp = Date()
            self.sessionID = sessionID
            self.content = content
            self.contentPartsJSON = Self.encode([.text(content)])
        }

        /// Creates a message from structured content parts.
        public init(
            role: MessageRole,
            contentParts: [MessagePart],
            sessionID: UUID
        ) {
            self.id = UUID()
            self.role = role
            self.timestamp = Date()
            self.sessionID = sessionID
            self.contentPartsJSON = Self.encode(contentParts)
            self.content = contentParts.compactMap(\.textContent).joined()
        }

        // MARK: - Content Parts

        /// The structured content parts of this message.
        public var contentParts: [MessagePart] {
            get { Self.decode(contentPartsJSON) }
            set {
                contentPartsJSON = Self.encode(newValue)
                content = newValue.compactMap(\.textContent).joined()
            }
        }

        // MARK: - JSON Helpers

        static func encode(_ parts: [MessagePart]) -> String {
            do {
                let data = try JSONEncoder().encode(parts)
                if let json = String(data: data, encoding: .utf8) {
                    return json
                }
                Log.persistence.warning("Failed to convert encoded MessagePart data to UTF-8 string")
            } catch {
                Log.persistence.error("Failed to encode MessagePart array: \(error)")
            }
            return "[]"
        }

        static func decode(_ json: String) -> [MessagePart] {
            guard let data = json.data(using: .utf8) else {
                Log.persistence.warning("contentPartsJSON is not valid UTF-8")
                return json.isEmpty ? [] : [.text(json)]
            }
            do {
                return try JSONDecoder().decode([MessagePart].self, from: data)
            } catch {
                Log.persistence.warning("Failed to decode contentPartsJSON, falling back to text: \(error)")
                return json.isEmpty ? [] : [.text(json)]
            }
        }
    }

    // ChatSession, SamplerPreset, APIEndpoint are unchanged from V1.
    // Redeclare typealiases so the schema enumerates all model types.
    typealias ChatSession = BaseChatSchemaV1.ChatSession
    typealias SamplerPreset = BaseChatSchemaV1.SamplerPreset
    typealias APIEndpoint = BaseChatSchemaV1.APIEndpoint
}

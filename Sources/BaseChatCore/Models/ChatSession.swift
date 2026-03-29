import Foundation
import SwiftData

/// A chat session containing a sequence of messages with its own settings.
///
/// Sessions hold per-session overrides for generation parameters. When an
/// override is `nil`, the app falls back to global defaults from `SettingsService`.
@Model
public final class ChatSession {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    /// Per-session system prompt.
    public var systemPrompt: String

    /// The UUID of the selected ModelInfo for this session.
    public var selectedModelID: UUID?

    // Per-session generation overrides (nil = use global default)
    public var temperature: Float?
    public var topP: Float?
    public var repeatPenalty: Float?

    /// Stored as PromptTemplate.rawValue; nil means auto-detect or global default.
    public var promptTemplateRawValue: String?

    /// User override for context window size; nil uses model default.
    public var contextSizeOverride: Int?

    /// Raw storage for CompressionMode. nil means .automatic.
    /// SwiftData lightweight migration handles this new optional column automatically.
    public var compressionModeRaw: String?

    /// Comma-separated UUID strings of pinned messages in this session.
    /// nil means no messages are pinned.
    public var pinnedMessageIDsRaw: String?

    public init(title: String = "New Chat") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.systemPrompt = ""
    }

    /// The set of pinned message IDs for this session.
    ///
    /// Pinned messages are preserved during context compression regardless of age.
    /// Serialized as comma-separated UUID strings in ``pinnedMessageIDsRaw``.
    public var pinnedMessageIDs: Set<UUID> {
        get {
            guard let raw = pinnedMessageIDsRaw else { return [] }
            return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }
        set {
            pinnedMessageIDsRaw = newValue.isEmpty ? nil : newValue.map(\.uuidString).joined(separator: ",")
        }
    }

    /// Convenience to get/set the prompt template as a `PromptTemplate` enum.
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

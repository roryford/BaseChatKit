import Foundation
import BaseChatInference
@preconcurrency import SwiftData

/// Schema v4 — adds first-class ``MessagePart/toolCall`` and
/// ``MessagePart/toolResult`` discriminators to the persisted
/// ``BaseChatSchemaV3/ChatMessage/contentPartsJSON`` payload.
///
/// The stored column (`contentPartsJSON: String`) is identical in V3 and V4;
/// only the JSON *contents* change — new tool-case discriminators are
/// recognised by the V4 decoder rather than falling back to `.text`. Because
/// no SwiftData column changes, V3 → V4 is a pure `.lightweight` migration.
///
/// All `@Model` classes are re-exported from V3 via `typealias` (SwiftData
/// keys models by their `PersistentModel.Type`, so the same class can be
/// registered in multiple schema versions without duplicating storage).
///
/// ## Forward plan
/// - V4 keeps the V3 `.text` fallback in the decoder as a safety net for any
///   still-circulating malformed rows.
/// - V5 will remove that fallback once the ecosystem has migrated.
public enum BaseChatSchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ChatMessage.self,
            ChatSession.self,
            SamplerPreset.self,
            APIEndpoint.self,
            ModelBenchmarkCache.self,
        ]
    }

    // Shape-compatible re-exports: V3's @Model classes are reused as-is. The
    // only thing that changed between V3 and V4 is the MessagePart Codable
    // vocabulary (tool-case discriminators are now decoded into their
    // proper cases instead of degrading to .text).
    public typealias ChatMessage = BaseChatSchemaV3.ChatMessage
    public typealias ChatSession = BaseChatSchemaV3.ChatSession
    public typealias SamplerPreset = BaseChatSchemaV3.SamplerPreset
    public typealias APIEndpoint = BaseChatSchemaV3.APIEndpoint
    public typealias ModelBenchmarkCache = BaseChatSchemaV3.ModelBenchmarkCache
}

// MARK: - Migration Plan

/// Registers every historical schema version and the migration stages between
/// them. Passed to ``ModelContainerFactory/makeContainer(configurations:)``
/// so stores opened against an older shape can be upgraded in place.
public enum BaseChatMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [BaseChatSchemaV3.self, BaseChatSchemaV4.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV3toV4]
    }

    /// V3 → V4 is purely additive at the JSON layer: the column shape is
    /// unchanged and old rows decode unmodified (with ``MessagePart``'s
    /// `.text` safety-net fallback still covering genuinely malformed
    /// blobs). New writes use the tool-case discriminators directly.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: BaseChatSchemaV3.self,
        toVersion: BaseChatSchemaV4.self
    )
}

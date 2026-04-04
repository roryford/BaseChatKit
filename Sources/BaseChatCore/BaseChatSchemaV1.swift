import SwiftData

/// Version 1 of the BaseChatKit SwiftData schema.
///
/// This is the baseline schema, formalising the initial set of `@Model` types.
/// No data transformation is required when migrating to this version — it is
/// the starting point for all future migrations.
///
/// ## Adding a new schema version
///
/// 1. Create `BaseChatSchemaV2` (or the next version) in a new file, e.g.
///    `BaseChatSchemaV2.swift`, following the same `VersionedSchema` pattern.
/// 2. List any renamed types as `typealias` inside the new enum, e.g.:
///    ```swift
///    typealias ChatSession = BaseChatSchemaV2.ChatSession
///    ```
/// 3. Add the new schema to `BaseChatMigrationPlan.schemas` (append to the array).
/// 4. Add a `MigrationStage` to `BaseChatMigrationPlan.stages`:
///    - Use `.lightweight(fromVersion:toVersion:)` if only new optional
///      attributes or renamed attributes are involved.
///    - Use `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` when
///      data transformation is required.
public enum BaseChatSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ChatMessage.self,
            ChatSession.self,
            SamplerPreset.self,
            APIEndpoint.self,
        ]
    }
}

/// The migration plan for BaseChatKit's SwiftData store.
///
/// `BaseChatMigrationPlan` lists every schema version in chronological order
/// and the migration stages that connect them.  Apps should pass this type to
/// `ModelContainerFactory.makeContainer()` (or directly to `ModelContainer`)
/// so that the store is upgraded automatically rather than deleted and
/// recreated on schema changes.
///
/// The plan currently contains a single schema version (`BaseChatSchemaV1`)
/// with no migration stages, which simply establishes V1 as the baseline.
/// Future versions append both a schema *and* a matching `MigrationStage`.
public enum BaseChatMigrationPlan: SchemaMigrationPlan {
    /// All schema versions in oldest-to-newest order.
    public static var schemas: [any VersionedSchema.Type] {
        [BaseChatSchemaV1.self]
    }

    /// Migration stages between consecutive schema versions.
    ///
    /// Empty for V1 — there is no prior version to migrate from.
    public static var stages: [MigrationStage] { [] }
}

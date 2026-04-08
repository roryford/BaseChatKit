import SwiftData

/// Creates `ModelContainer` instances pre-configured with ``BaseChatMigrationPlan``.
///
/// Use `ModelContainerFactory` instead of constructing `ModelContainer` by hand
/// so that your store is automatically migrated whenever the schema changes.
///
/// ```swift
/// // On-disk store (typical app setup)
/// let container = try ModelContainerFactory.makeContainer()
///
/// // In-memory store (tests, previews, ephemeral sessions)
/// let container = try ModelContainerFactory.makeInMemoryContainer()
/// ```
package enum ModelContainerFactory {
    /// The newest schema version that should be opened for application stores.
    package static var currentSchema: any VersionedSchema.Type {
        BaseChatMigrationPlan.schemas.last ?? BaseChatSchemaV1.self
    }

    /// Returns an on-disk `ModelContainer` configured with ``BaseChatMigrationPlan``.
    ///
    /// - Parameter configurations: Additional `ModelConfiguration` values to
    ///   pass to `ModelContainer`. Defaults to a single default (on-disk) config.
    /// - Returns: A `ModelContainer` whose store will be automatically migrated.
    /// - Throws: If `ModelContainer` initialisation fails.
    package static func makeContainer(
        configurations: [ModelConfiguration] = [ModelConfiguration()]
    ) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: currentSchema),
            migrationPlan: BaseChatMigrationPlan.self,
            configurations: configurations
        )
    }

    /// Returns an ephemeral in-memory `ModelContainer` configured with
    /// ``BaseChatMigrationPlan``.
    ///
    /// Suitable for tests, SwiftUI previews, and any context where data must
    /// not be persisted to disk.
    ///
    /// - Returns: An in-memory `ModelContainer`.
    /// - Throws: If `ModelContainer` initialisation fails.
    package static func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try makeContainer(configurations: [config])
    }
}

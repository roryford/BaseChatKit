import SwiftData

/// Creates `ModelContainer` instances configured with the current schema.
///
/// Use `ModelContainerFactory` instead of constructing `ModelContainer` by hand.
///
/// ```swift
/// // On-disk store (typical app setup)
/// let container = try ModelContainerFactory.makeContainer()
///
/// // In-memory store (tests, previews, ephemeral sessions)
/// let container = try ModelContainerFactory.makeInMemoryContainer()
/// ```
public enum ModelContainerFactory {
    /// The current schema version.
    public static var currentSchema: any VersionedSchema.Type {
        BaseChatSchemaV3.self
    }

    /// Returns an on-disk `ModelContainer` configured with the current schema.
    ///
    /// - Parameter configurations: Additional `ModelConfiguration` values to
    ///   pass to `ModelContainer`. Defaults to a single default (on-disk) config.
    /// - Returns: A `ModelContainer` using the current schema.
    /// - Throws: If `ModelContainer` initialisation fails.
    public static func makeContainer(
        configurations: [ModelConfiguration] = [ModelConfiguration()]
    ) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: currentSchema),
            configurations: configurations
        )
    }

    /// Returns an ephemeral in-memory `ModelContainer` configured with the
    /// current schema.
    ///
    /// Suitable for tests, SwiftUI previews, and any context where data must
    /// not be persisted to disk.
    ///
    /// - Returns: An in-memory `ModelContainer`.
    /// - Throws: If `ModelContainer` initialisation fails.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try makeContainer(configurations: [config])
    }
}

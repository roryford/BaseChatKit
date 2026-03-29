import Foundation
import SwiftData
import BaseChatCore

/// Creates an in-memory `ModelContainer` suitable for unit and integration tests.
///
/// Uses `BaseChatSchema.allModelTypes` so that all SwiftData models (ChatMessage,
/// ChatSession, SamplerPreset, APIEndpoint) are registered. The container is
/// ephemeral --- nothing touches disk.
///
/// - Returns: A configured `ModelContainer` with in-memory storage.
/// - Throws: If `ModelContainer` initialisation fails (should not happen with
///   an in-memory configuration).
public func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema(BaseChatSchema.allModelTypes)
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

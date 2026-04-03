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

// MARK: - E2E Temp Directory & GGUF Helpers

/// GGUF magic bytes: "GGUF" in ASCII.
public let ggufMagic: [UInt8] = [0x47, 0x47, 0x55, 0x46]

/// Creates a unique temporary directory for one test.
public func makeE2ETempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("BaseChatE2E-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Removes a file or directory, ignoring errors.
public func cleanupE2ETempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Collects all tokens from an async throwing stream into a single string.
public func collectTokens(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var tokens: [String] = []
    for try await token in stream {
        tokens.append(token)
    }
    return tokens.joined()
}

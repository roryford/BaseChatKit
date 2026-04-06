import Foundation
import SwiftData
import BaseChatCore

/// Creates an in-memory `ModelContainer` suitable for unit and integration tests.
///
/// Delegates to ``ModelContainerFactory/makeInMemoryContainer()`` so the
/// container is configured with ``BaseChatMigrationPlan`` — the same plan used
/// in production. All SwiftData models (ChatMessage, ChatSession, SamplerPreset,
/// APIEndpoint) are registered. The container is ephemeral — nothing touches disk.
///
/// - Returns: A configured `ModelContainer` with in-memory storage.
/// - Throws: If `ModelContainer` initialisation fails (should not happen with
///   an in-memory configuration).
public func makeInMemoryContainer() throws -> ModelContainer {
    try ModelContainerFactory.makeInMemoryContainer()
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

/// Collects all token text from a generation event stream into a single string.
public func collectTokens(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async throws -> String {
    var tokens: [String] = []
    for try await event in stream {
        if case .token(let text) = event {
            tokens.append(text)
        }
    }
    return tokens.joined()
}

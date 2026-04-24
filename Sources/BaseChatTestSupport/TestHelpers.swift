import Foundation
import SwiftData
import BaseChatCore
import BaseChatInference

/// Creates an in-memory `ModelContainer` suitable for unit and integration tests.
///
/// Delegates to ``ModelContainerFactory/makeInMemoryContainer()`` so the
/// container is configured with the current schema — the same setup used
/// in production. All SwiftData models (ChatMessage, ChatSession, SamplerPreset,
/// APIEndpoint, ModelBenchmarkCache) are registered. The container is ephemeral — nothing touches disk.
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

// MARK: - Isolated Models Directory

/// Returns a fresh per-test temporary directory suitable for use as a
/// `ModelStorageService` base directory.
///
/// Every test that writes fake model files (GGUF placeholders, MLX folders,
/// non-model garbage) must route those writes through an isolated directory
/// — never the real `<Documents>/Models` path. Writing to the production
/// path pollutes the developer's demo app and can cause the model scanner
/// to surface stub files as if they were real models (see #379).
///
/// Use the returned URL when constructing `ModelStorageService(baseDirectory:)`
/// or `makeIsolatedModelStorage()` — the caller is responsible for passing the
/// same URL when cleanup needs to remove the directory in `tearDown`.
public func makeIsolatedModelsDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BaseChatModelsScratch-\(UUID().uuidString)", isDirectory: true)
}

/// Builds a `ModelStorageService` rooted at a fresh isolated temp directory
/// and returns both so the test can clean up the directory in `tearDown`.
///
/// This is the canonical way for tests to exercise the storage service
/// without touching the user's real `<Documents>/Models` path.
public func makeIsolatedModelStorage(
    fileManager: FileManager = .default
) -> (service: ModelStorageService, directory: URL) {
    let dir = makeIsolatedModelsDirectory()
    let service = ModelStorageService(fileManager: fileManager, baseDirectory: dir)
    return (service, dir)
}

/// Extracts a `CloudBackendError` from an error that may be wrapped in `RetryExhaustedError`.
///
/// Retryable errors that exhaust all retry attempts arrive wrapped in
/// `RetryExhaustedError`. Non-retryable errors pass through raw. This helper
/// handles both cases so tests can assert on the underlying `CloudBackendError`.
public func extractCloudError(_ error: any Error) -> CloudBackendError? {
    if let cloud = error as? CloudBackendError {
        return cloud
    }
    if let exhausted = error as? RetryExhaustedError,
       let cloud = exhausted.lastError as? CloudBackendError {
        return cloud
    }
    return nil
}

/// Collects all token text from a generation event stream into a single string.
public func collectTokens(_ stream: GenerationStream) async throws -> String {
    var tokens: [String] = []
    for try await event in stream.events {
        if case .token(let text) = event {
            tokens.append(text)
        }
    }
    return tokens.joined()
}

// MARK: - Bounded async timeout

/// Error thrown by ``withTimeout(_:file:line:_:)`` when the wrapped operation
/// exceeds its deadline.
public enum TimeoutError: Error, CustomStringConvertible, Equatable {
    case timedOut(Duration)

    public var description: String {
        switch self {
        case .timedOut(let duration):
            return "Operation timed out after \(duration)"
        }
    }
}

/// Runs `operation` with a bounded deadline. If it exceeds `timeout` the
/// operation's task is cancelled and ``TimeoutError/timedOut(_:)`` is thrown.
///
/// Used to convert sabotage-check hangs into deterministic failures per the
/// repo's test conventions (see CLAUDE.md — "no artificial sleep/fixed
/// timeouts — use XCTestExpectation / XCTWaiter with tight deadlines", and
/// the sabotage-verify rule which requires bounded, visible failures).
///
/// Implementation is a `TaskGroup` race between the user operation and a
/// `Task.sleep(for:)` deadline — whichever finishes first wins and the
/// sibling is cancelled. Bookkeeping overhead is O(1).
///
/// - Parameters:
///   - timeout: Maximum duration the operation may run before failing.
///   - operation: The async operation to run.
/// - Returns: The operation's result when it completes within `timeout`.
/// - Throws: ``TimeoutError/timedOut(_:)`` if the deadline elapses first;
///   otherwise rethrows any error from `operation`.
@discardableResult
public func withTimeout<T: Sendable>(
    _ timeout: Duration,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError.timedOut(timeout)
        }
        // First completion wins; cancel the sibling before returning.
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            // Unreachable — we added two child tasks above.
            throw TimeoutError.timedOut(timeout)
        }
        return result
    }
}

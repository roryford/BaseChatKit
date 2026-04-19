import Foundation

/// Produces `FuzzRunner.BackendHandle` values for the fuzz runner.
///
/// Factories are plain `Sendable` structs, which keeps them trivially unit-testable
/// and lets multi-backend drivers (`#501 --model all`) iterate an array of them.
/// The runner calls `makeHandle()` when it needs a backend — today once at the
/// start of `run`, but future rotation/multi-turn modes may call it repeatedly.
public protocol FuzzBackendFactory: Sendable {
    /// Construct a fresh `BackendHandle`. Called once per fuzz iteration when
    /// the runner needs a backend (e.g., rotation in #501, or first use today).
    func makeHandle() async throws -> FuzzRunner.BackendHandle
}

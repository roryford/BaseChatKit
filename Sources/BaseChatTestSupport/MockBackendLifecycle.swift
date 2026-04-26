import Foundation
import BaseChatInference

/// Composition helper that unifies the `Task` + cancellation + state-lock
/// dance every test mock backend used to hand-roll.
///
/// Three test mock backends (`ChaosBackend`, `PerceivedLatencyBackend`,
/// `SlowMockBackend`) all need the same lifecycle plumbing around their
/// `generate()` implementation:
///
/// - kick off an `AsyncThrowingStream` whose continuation is fed by a `Task`
/// - wire `continuation.onTermination` so a dropped consumer cancels the task
/// - record the task so an external `cancelGeneration()` can stop it
/// - clear the slot when the task finishes naturally
/// - flip the per-backend `_isGenerating` flag back to `false` once the body
///   returns, regardless of whether it threw, finished, or was cancelled
///
/// The body closure is responsible for the actual token production. The
/// `onFinish` closure is the per-backend "I'm done generating" signal — it
/// runs under the backend's own `NSLock`, so each conformer keeps its own
/// state-lock discipline.
///
/// ## Termination ordering
///
/// `body()` runs to completion → `onFinish()` fires → `continuation.finish()`
/// is called → `clearTask()` clears the slot. `onFinish` runs *before*
/// `continuation.finish()` so that consumers iterating `events` see the
/// `isGenerating == false` state before their `for try await` loop exits —
/// matching the original `defer { finishGeneration() }` ordering.
///
/// ## Why a class, not a `@MainActor` protocol
///
/// The conformer classes are `final class @unchecked Sendable` with
/// non-`@MainActor` `deinit`s. A `@MainActor protocol ... { var generationTask:
/// Task<Void, Never>? { get set } }` would (a) be unsatisfiable by stored
/// properties on non-`@MainActor` classes under Swift 6 strict concurrency,
/// (b) make the existing `deinit` cancellation illegal, and (c) collide with
/// the existing `NSLock` discipline. Composition keeps each backend's
/// concurrency story intact.
package final class MockBackendLifecycle: @unchecked Sendable {
    private let stateLock = NSLock()
    private var generationTask: Task<Void, Never>?

    package init() {}

    /// Records the active generation task. Replaces any previously recorded
    /// task without cancelling it — callers are expected to clear the slot
    /// from inside the task's own completion block.
    package func setTask(_ task: Task<Void, Never>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        generationTask = task
    }

    /// Drops the recorded task reference. Called from the task's own
    /// completion path so back-to-back `makeStream` calls never see a
    /// stale slot.
    package func clearTask() {
        stateLock.lock()
        defer { stateLock.unlock() }
        generationTask = nil
    }

    /// Test-only: reports whether the task slot is currently occupied.
    /// Used by `MockBackendLifecycleTests` to prove `clearTask()` ran on
    /// the natural completion path.
    package var hasActiveTask: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generationTask != nil
    }

    /// Cancels the recorded task and clears the slot. Safe to call from
    /// `deinit` (the lock is released before `task.cancel()` so the task's
    /// own state-flip cannot deadlock).
    package func cancel() {
        stateLock.lock()
        let task = generationTask
        generationTask = nil
        stateLock.unlock()
        task?.cancel()
    }

    /// Builds a `GenerationStream` whose underlying task runs `body` and
    /// then signals completion via `onFinish`.
    ///
    /// - Parameters:
    ///   - onFinish: Per-backend "generation finished" signal. Runs inside
    ///     the underlying task on the same hop as `body`'s natural exit,
    ///     and runs *before* the stream's continuation is finished so that
    ///     consumers see the post-generation state on their last awaited
    ///     iteration. Always fires exactly once, even when `body` throws or
    ///     returns early.
    ///   - body: The token-producing closure. It owns yielding events and
    ///     handling cancellation; it must not call `continuation.finish()`
    ///     itself — the helper does that after the closure returns.
    package func makeStream(
        onFinish: @escaping @Sendable () -> Void,
        body: @escaping @Sendable (AsyncThrowingStream<GenerationEvent, Error>.Continuation) async -> Void
    ) -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
            let task = Task { [weak self] in
                await body(continuation)
                // Signal finish *before* closing the stream so the consumer
                // sees the post-generation state on its last iteration —
                // matches the original `defer { finishGeneration() }` order.
                onFinish()
                continuation.finish()
                self?.clearTask()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
            self?.setTask(task)
        }
        return GenerationStream(stream)
    }
}

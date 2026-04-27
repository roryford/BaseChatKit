import Foundation
import BaseChatCore

/// In-memory ``BackgroundTaskScheduler`` for tests.
///
/// `schedule` runs the closure on a detached task immediately, recording the
/// identifier and budget. Tests can drive cancellation either explicitly via
/// ``BackgroundTaskScheduler/cancel(identifier:)`` or by calling
/// ``simulateMemoryBudgetExceeded(identifier:)`` to mimic the watchdog path
/// without actually allocating memory.
///
/// `await waitForFinish(identifier:)` blocks until the recorded task settles,
/// removing the need for fixed sleeps in tests.
///
/// Thread-safe via `NSLock`.
public final class MockBackgroundTaskScheduler: BackgroundTaskScheduler, @unchecked Sendable {

    // MARK: - Recorded Calls

    public struct ScheduledCall: Sendable {
        public let identifier: String
        public let budget: MemoryBudget
    }

    private let lock = NSLock()
    private var _calls: [ScheduledCall] = []
    private var _cancellations: [String] = []
    private var _tasks: [String: Task<Void, Never>] = [:]

    /// Every call to ``schedule(identifier:budget:work:)``, in order.
    public var calls: [ScheduledCall] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    /// Every identifier passed to ``cancel(identifier:)``, in order.
    public var cancellations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _cancellations
    }

    public init() {}

    // MARK: - BackgroundTaskScheduler

    public func schedule(
        identifier: String,
        budget: MemoryBudget,
        work: @Sendable @escaping () async throws -> Void
    ) async {
        // Cancel any prior run under this identifier — same contract as the
        // production scheduler.
        cancel(identifier: identifier)

        lock.withLock { _calls.append(ScheduledCall(identifier: identifier, budget: budget)) }

        let task = Task.detached {
            do {
                try await work()
            } catch {
                // Same swallow contract as the production scheduler.
            }
        }

        lock.withLock { _tasks[identifier] = task }
    }

    public func cancel(identifier: String) {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let task = _tasks.removeValue(forKey: identifier)
            if task != nil {
                // Only record cancellations that actually cancelled a running
                // task. The implicit pre-clean cancel inside `schedule` shouldn't
                // pollute the test-visible record when there's nothing to remove.
                _cancellations.append(identifier)
            }
            return task
        }
        task?.cancel()
    }

    // MARK: - Test Helpers

    /// Simulates the watchdog observing a memory-budget breach for the
    /// in-flight task under `identifier`. The task is cancelled exactly the
    /// way ``DefaultBackgroundTaskScheduler`` would cancel it on a real
    /// `phys_footprint` overrun.
    public func simulateMemoryBudgetExceeded(identifier: String) {
        lock.lock()
        let task = _tasks.removeValue(forKey: identifier)
        lock.unlock()
        task?.cancel()
    }

    /// Awaits the in-flight task for `identifier`. Returns immediately if no
    /// task is recorded under that identifier.
    public func waitForFinish(identifier: String) async {
        let task = lock.withLock { _tasks[identifier] }
        await task?.value
    }
}

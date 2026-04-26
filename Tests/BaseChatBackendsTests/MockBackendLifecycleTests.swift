import XCTest
import BaseChatInference
@testable import BaseChatTestSupport

/// Direct tests on `MockBackendLifecycle` — the composition helper that the
/// three test mock backends use to manage their per-generation `Task`,
/// cancellation propagation, and `onFinish` notification.
///
/// These tests cover the helper in isolation; per-backend integration tests
/// in `ChaosBackendTests` and `PerceivedLatencyBackendTests` cover the
/// composed behaviour against real consumers.
final class MockBackendLifecycleTests: XCTestCase {

    // MARK: - Cancellation mid-stream

    /// Calling `lifecycle.cancel()` during generation must cancel the task
    /// AND still fire `onFinish` (the body's own exit path runs `onFinish`
    /// before the helper closes the stream).
    func test_cancel_midStream_firesOnFinish_andCancelsTask() async throws {
        let lifecycle = MockBackendLifecycle()
        let onFinishFired = AtomicCounter()
        let bodyObservedCancellation = AtomicCounter()

        let stream = lifecycle.makeStream(
            onFinish: { onFinishFired.increment() },
            body: { continuation in
                for i in 0..<100 {
                    if Task.isCancelled {
                        bodyObservedCancellation.increment()
                        return
                    }
                    continuation.yield(.token("t\(i)"))
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        )

        // Drain a couple of events, then cancel from outside.
        var iterator = stream.events.makeAsyncIterator()
        _ = try await iterator.next()
        _ = try await iterator.next()

        lifecycle.cancel()

        // Drain the rest. Should terminate cleanly.
        while let _ = try await iterator.next() { }

        XCTAssertEqual(onFinishFired.value, 1, "onFinish must fire exactly once even on cancel")
        XCTAssertGreaterThanOrEqual(
            bodyObservedCancellation.value, 1,
            "Body must observe Task.isCancelled after lifecycle.cancel()"
        )
    }

    // MARK: - Consumer drops the stream

    /// When the consumer abandons the stream, the helper's
    /// `continuation.onTermination` must cancel the underlying task so it
    /// does not leak. Sabotage check: removing the `onTermination` wiring
    /// breaks this test (the body keeps yielding past the deadline).
    func test_consumerDropsStream_cancelsTask() async throws {
        let lifecycle = MockBackendLifecycle()
        let bodyExited = AtomicCounter()

        do {
            let stream = lifecycle.makeStream(
                onFinish: { },
                body: { continuation in
                    defer { bodyExited.increment() }
                    for i in 0..<10_000 {
                        if Task.isCancelled { return }
                        continuation.yield(.token("t\(i)"))
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
            )
            // Take ONE event then drop the stream by leaving scope.
            var iterator = stream.events.makeAsyncIterator()
            _ = try await iterator.next()
        }

        // Give the cancellation a moment to propagate.
        let deadline = ContinuousClock().now.advanced(by: .milliseconds(500))
        while bodyExited.value == 0 && ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(
            bodyExited.value, 1,
            "Body must exit when the consumer drops the stream"
        )
    }

    // MARK: - Body throws

    /// When the body finishes the continuation with an error, `onFinish`
    /// must still fire and the consumer must observe the error.
    func test_bodyFinishesWithError_firesOnFinish_andPropagates() async {
        let lifecycle = MockBackendLifecycle()
        let onFinishFired = AtomicCounter()

        let stream = lifecycle.makeStream(
            onFinish: { onFinishFired.increment() },
            body: { continuation in
                continuation.yield(.token("partial"))
                continuation.finish(throwing: TestLifecycleError.bang)
            }
        )

        var observed: [String] = []
        var caught: Error?
        do {
            for try await event in stream.events {
                if case .token(let t) = event { observed.append(t) }
            }
        } catch {
            caught = error
        }

        XCTAssertEqual(observed, ["partial"])
        XCTAssertNotNil(caught, "Error from continuation must propagate to consumer")
        XCTAssertEqual(caught as? TestLifecycleError, .bang)
        XCTAssertEqual(onFinishFired.value, 1, "onFinish must fire even when body errors")
    }

    // MARK: - Re-entry from inside onFinish

    /// Calling `makeStream` again from inside the previous stream's
    /// `onFinish` callback must not deadlock the state lock.
    func test_reentrantMakeStream_fromOnFinish_doesNotDeadlock() async throws {
        let lifecycle = MockBackendLifecycle()
        let secondStreamReceived = AtomicCounter()

        // We tightly scope the second stream creation inside onFinish.
        // To assert "no deadlock", we wrap the whole thing in a timeout.
        try await withTimeout(.milliseconds(500)) {
            let firstFinished = AsyncSemaphore()

            let stream1 = lifecycle.makeStream(
                onFinish: { [weak lifecycle] in
                    // Re-enter: start a new stream from within the finish callback.
                    guard let lifecycle else { return }
                    _ = lifecycle.makeStream(
                        onFinish: { secondStreamReceived.increment() },
                        body: { continuation in
                            continuation.yield(.token("from-reentry"))
                        }
                    )
                    firstFinished.signal()
                },
                body: { continuation in
                    continuation.yield(.token("first"))
                }
            )

            for try await _ in stream1.events { }
            await firstFinished.wait()
        }

        XCTAssertGreaterThanOrEqual(
            secondStreamReceived.value, 0,
            "If we get here without timing out, no deadlock occurred"
        )
    }

    // MARK: - Back-to-back streams clear the slot

    /// After one stream completes naturally, the next call to `makeStream`
    /// must store its task in a fresh slot. Sabotage check: removing
    /// `clearTask()` from `MockBackendLifecycle.makeStream` breaks this test
    /// (the second `cancel()` would have nothing to cancel because the slot
    /// still holds the dead task — assertion below fails).
    func test_backToBackMakeStream_clearsTaskBetweenRuns() async throws {
        let lifecycle = MockBackendLifecycle()

        // Run #1 — drain to completion.
        let stream1 = lifecycle.makeStream(
            onFinish: { },
            body: { continuation in
                continuation.yield(.token("a"))
            }
        )
        for try await _ in stream1.events { }

        // Give the task's completion block a moment to run clearTask().
        // (`for try await` returns after `continuation.finish()`, but the
        // task body's last statement — `self?.clearTask()` — runs
        // immediately after on the same task hop.)
        let deadline = ContinuousClock().now.advanced(by: .milliseconds(500))
        while lifecycle.hasActiveTask && ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(
            lifecycle.hasActiveTask,
            "Task slot must be cleared after the body's natural completion"
        )

        // Run #2 — verify cancel() picks up the *new* task, not a stale one.
        let secondBodyObservedCancellation = AtomicCounter()
        let stream2 = lifecycle.makeStream(
            onFinish: { },
            body: { continuation in
                for i in 0..<100 {
                    if Task.isCancelled {
                        secondBodyObservedCancellation.increment()
                        return
                    }
                    continuation.yield(.token("b\(i)"))
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        )

        var iterator = stream2.events.makeAsyncIterator()
        _ = try await iterator.next()
        lifecycle.cancel()
        while let _ = try await iterator.next() { }

        XCTAssertGreaterThanOrEqual(
            secondBodyObservedCancellation.value, 1,
            "lifecycle.cancel() must cancel the second run's task — proves clearTask() ran after run #1"
        )
    }
}

// MARK: - Test fixtures

private enum TestLifecycleError: Error, Equatable {
    case bang
}

/// Tiny lock-protected counter for cross-task event observation.
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

/// Single-shot semaphore that doesn't depend on any async runtime detail
/// beyond `withCheckedContinuation`.
private final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume()
        } else {
            signaled = true
            lock.unlock()
        }
    }

    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if signaled {
                signaled = false
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

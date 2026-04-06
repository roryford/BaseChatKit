import XCTest
@testable import BaseChatCore

final class CircuitBreakerTests: XCTestCase {

    // MARK: - Initial State

    func test_initialStateIsClosed() async {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: .seconds(1))
        let state = await cb.state
        XCTAssertEqual(state, .closed)
    }

    // MARK: - Closed State

    func test_closedState_passesThrough() async throws {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: .seconds(1))
        let result = try await cb.execute { "ok" }
        XCTAssertEqual(result, "ok")
    }

    func test_closedState_countsFailures() async {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: .seconds(60))

        for _ in 0..<2 {
            do { _ = try await cb.execute { throw TestError() } } catch {}
        }

        let state = await cb.state
        XCTAssertEqual(state, .closed, "Should stay closed below threshold")
    }

    func test_closedState_opensAfterThreshold() async {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: .seconds(60))

        for _ in 0..<3 {
            do { _ = try await cb.execute { throw TestError() } } catch {}
        }

        let state = await cb.state
        XCTAssertEqual(state, .open)
    }

    // MARK: - Open State

    func test_openState_throwsImmediately() async {
        let cb = CircuitBreaker(failureThreshold: 1, resetTimeout: .seconds(60))
        do { _ = try await cb.execute { throw TestError() } } catch {}

        do {
            _ = try await cb.execute { "should not run" }
            XCTFail("Should have thrown CircuitBreakerOpenError")
        } catch {
            XCTAssertTrue(error is CircuitBreakerOpenError)
        }
    }

    // MARK: - Half-Open State

    func test_halfOpen_closesOnSuccess() async throws {
        let cb = CircuitBreaker(failureThreshold: 1, resetTimeout: .milliseconds(50))
        do { _ = try await cb.execute { throw TestError() } } catch {}

        // Wait for reset timeout.
        try await Task.sleep(for: .milliseconds(100))

        let result = try await cb.execute { "recovered" }
        XCTAssertEqual(result, "recovered")

        let state = await cb.state
        XCTAssertEqual(state, .closed)
    }

    func test_halfOpen_reopensOnFailure() async throws {
        let cb = CircuitBreaker(failureThreshold: 1, resetTimeout: .milliseconds(50))
        do { _ = try await cb.execute { throw TestError() } } catch {}

        try await Task.sleep(for: .milliseconds(100))

        do { _ = try await cb.execute { throw TestError() } } catch {}

        let state = await cb.state
        XCTAssertEqual(state, .open)
    }

    // MARK: - Reset

    func test_manualResetReturnsToClosed() async {
        let cb = CircuitBreaker(failureThreshold: 1, resetTimeout: .seconds(60))
        do { _ = try await cb.execute { throw TestError() } } catch {}

        let openState = await cb.state
        XCTAssertEqual(openState, .open)

        await cb.reset()
        let resetState = await cb.state
        XCTAssertEqual(resetState, .closed)
    }

    // MARK: - Success Resets Counter

    func test_successResetsConsecutiveFailureCount() async throws {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: .seconds(60))

        // Two failures, then a success.
        do { _ = try await cb.execute { throw TestError() } } catch {}
        do { _ = try await cb.execute { throw TestError() } } catch {}
        _ = try await cb.execute { "ok" }

        // Two more failures — still below threshold because counter was reset.
        do { _ = try await cb.execute { throw TestError() } } catch {}
        do { _ = try await cb.execute { throw TestError() } } catch {}

        let state = await cb.state
        XCTAssertEqual(state, .closed, "Counter should have reset after success")
    }
}

private struct TestError: Error {}

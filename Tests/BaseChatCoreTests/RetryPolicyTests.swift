import XCTest
@testable import BaseChatCore

final class RetryPolicyTests: XCTestCase {

    // MARK: - Success on First Attempt

    func test_success_noRetry() async throws {
        var callCount = 0
        let result = try await withExponentialBackoff {
            callCount += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1, "Should only call operation once on success")
    }

    // MARK: - Retry on Rate Limit

    func test_retryOnRateLimit_succeedsAfterRetry() async throws {
        var callCount = 0
        let result: String = try await withExponentialBackoff(baseDelay: 0.01) {
            callCount += 1
            if callCount < 3 {
                throw CloudBackendError.rateLimited(retryAfter: 0.01)
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount, 3, "Should retry twice before succeeding")
    }

    // MARK: - Non-Rate-Limit Errors Thrown Immediately

    func test_nonRateLimitError_throwsImmediately() async {
        var callCount = 0
        do {
            _ = try await withExponentialBackoff {
                callCount += 1
                throw CloudBackendError.authenticationFailed(provider: "Test")
            }
            XCTFail("Should have thrown")
        } catch {
            guard case CloudBackendError.authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got: \(error)")
                return
            }
        }
        XCTAssertEqual(callCount, 1, "Should not retry on non-rate-limit errors")
    }

    // MARK: - Max Retries Exhausted

    func test_maxRetriesExhausted_throws() async {
        var callCount = 0
        do {
            _ = try await withExponentialBackoff(maxRetries: 2, baseDelay: 0.01) {
                callCount += 1
                throw CloudBackendError.rateLimited(retryAfter: 0.01)
            }
            XCTFail("Should have thrown after max retries")
        } catch {
            guard case CloudBackendError.rateLimited = error else {
                XCTFail("Expected rateLimited, got: \(error)")
                return
            }
        }
        // 1 initial + 2 retries = 3 total attempts
        XCTAssertEqual(callCount, 3, "Should attempt maxRetries + 1 times")
    }

    // MARK: - Total Delay Cap

    func test_totalDelayCapRespected() async {
        var callCount = 0
        do {
            _ = try await withExponentialBackoff(maxRetries: 10, baseDelay: 0.01, maxTotalDelay: 0.02) {
                callCount += 1
                throw CloudBackendError.rateLimited(retryAfter: 0.05)
            }
            XCTFail("Should have thrown when total delay exceeded")
        } catch {
            guard case CloudBackendError.rateLimited = error else {
                XCTFail("Expected rateLimited, got: \(error)")
                return
            }
        }
        // Should stop retrying before exhausting all 10 retries.
        XCTAssertLessThan(callCount, 10, "Should stop before max retries due to delay cap")
    }

    // MARK: - Uses Retry-After Header

    func test_usesRetryAfterWhenProvided() async throws {
        var callCount = 0
        let start = Date()
        let result: String = try await withExponentialBackoff(maxRetries: 1, baseDelay: 10.0) {
            callCount += 1
            if callCount == 1 {
                // retryAfter of 0.05s should override the 10s baseDelay
                throw CloudBackendError.rateLimited(retryAfter: 0.05)
            }
            return "ok"
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, "ok")
        XCTAssertLessThan(elapsed, 2.0, "Should use retryAfter (0.05s) not baseDelay (10s)")
    }
}

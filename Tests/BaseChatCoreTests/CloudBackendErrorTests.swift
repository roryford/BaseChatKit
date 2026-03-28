import XCTest
@testable import BaseChatCore

/// Tests for CloudBackendError descriptions.
final class CloudBackendErrorTests: XCTestCase {

    func test_authenticationFailed_includesProvider() {
        let error = CloudBackendError.authenticationFailed(provider: "Claude")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("Claude"),
                      "Error should include the provider name: \(description)")
    }

    func test_rateLimited_withRetryAfter() {
        let error = CloudBackendError.rateLimited(retryAfter: 30)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("30"),
                      "Should include retry-after seconds: \(description)")
    }

    func test_rateLimited_withoutRetryAfter() {
        let error = CloudBackendError.rateLimited(retryAfter: nil)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.lowercased().contains("rate limited"),
                      "Should mention rate limiting: \(description)")
        XCTAssertFalse(description.contains("seconds"),
                       "Should not mention seconds when retryAfter is nil")
    }

    func test_serverError_includesCodeAndMessage() {
        let error = CloudBackendError.serverError(statusCode: 500, message: "Internal failure")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("500"),
                      "Should include status code: \(description)")
        XCTAssertTrue(description.contains("Internal failure"),
                      "Should include error message: \(description)")
    }

    func test_missingAPIKey_description() {
        let error = CloudBackendError.missingAPIKey
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty, "missingAPIKey should have a description")
        XCTAssertTrue(description.lowercased().contains("api key"),
                      "Should mention API key: \(description)")
    }

    func test_allCases_haveNonNilDescription() {
        let errors: [CloudBackendError] = [
            .invalidURL("https://bad"),
            .authenticationFailed(provider: "Test"),
            .rateLimited(retryAfter: 10),
            .rateLimited(retryAfter: nil),
            .serverError(statusCode: 503, message: "Service unavailable"),
            .networkError(underlying: URLError(.notConnectedToInternet)),
            .parseError("unexpected token"),
            .missingAPIKey,
            .streamInterrupted,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                            "\(error) should have a non-nil description")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true,
                           "\(error) should have a non-empty description")
        }
    }
}

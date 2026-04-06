import XCTest
@testable import BaseChatBackends

final class URLSessionProviderTests: XCTestCase {

    func test_pinnedSession_hasExpectedTimeouts() {
        let session = URLSessionProvider.pinned
        // Sabotage check: changing timeoutIntervalForRequest in URLSessionProvider causes this to fail
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 300,
                       "Pinned session request timeout should be 300s")
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 600,
                       "Pinned session resource timeout should be 600s")
    }

    func test_unpinnedSession_hasExpectedTimeouts() {
        let session = URLSessionProvider.unpinned
        // Sabotage check: changing timeoutIntervalForRequest in URLSessionProvider causes this to fail
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 300,
                       "Unpinned session request timeout should be 300s")
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 600,
                       "Unpinned session resource timeout should be 600s")
    }

    func test_pinnedSession_hasPinnedDelegate() {
        let session = URLSessionProvider.pinned
        // Sabotage check: removing the PinnedSessionDelegate assignment causes this to fail
        XCTAssertTrue(session.delegate is PinnedSessionDelegate,
                      "Pinned session should use PinnedSessionDelegate")
    }

    func test_unpinnedSession_hasNoDelegate() {
        let session = URLSessionProvider.unpinned
        // Sabotage check: assigning a delegate to the unpinned session causes this to fail
        XCTAssertNil(session.delegate,
                     "Unpinned session should not have a delegate")
    }

    func test_pinnedAndUnpinned_areDifferentInstances() {
        // Sabotage check: returning the same session instance for both causes this to fail
        XCTAssertFalse(URLSessionProvider.pinned === URLSessionProvider.unpinned,
                       "Pinned and unpinned sessions should be different instances")
    }
}

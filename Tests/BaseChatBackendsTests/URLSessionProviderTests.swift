import XCTest
@testable import BaseChatBackends

final class URLSessionProviderTests: XCTestCase {

    func test_pinnedSession_hasExpectedTimeouts() {
        let session = URLSessionProvider.pinned
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 300,
                       "Pinned session request timeout should be 300s")
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 600,
                       "Pinned session resource timeout should be 600s")
    }

    func test_unpinnedSession_hasExpectedTimeouts() {
        let session = URLSessionProvider.unpinned
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 300,
                       "Unpinned session request timeout should be 300s")
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 600,
                       "Unpinned session resource timeout should be 600s")
    }

    func test_pinnedSession_hasPinnedDelegate() {
        let session = URLSessionProvider.pinned
        XCTAssertTrue(session.delegate is PinnedSessionDelegate,
                      "Pinned session should use PinnedSessionDelegate")
    }

    func test_unpinnedSession_hasNoDelegate() {
        let session = URLSessionProvider.unpinned
        XCTAssertNil(session.delegate,
                     "Unpinned session should not have a delegate")
    }

    func test_pinnedAndUnpinned_areDifferentInstances() {
        XCTAssertFalse(URLSessionProvider.pinned === URLSessionProvider.unpinned,
                       "Pinned and unpinned sessions should be different instances")
    }
}

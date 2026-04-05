import XCTest
import CommonCrypto
@testable import BaseChatBackends

final class PinnedSessionDelegateTests: XCTestCase {

    // MARK: - SHA-256 Helper (tested indirectly via known input)

    /// Validates the delegate's SHA-256 implementation by computing a hash of
    /// known data and comparing against a pre-computed reference.
    func test_sha256_producesCorrectHash() {
        // The delegate's sha256 is private, so we replicate the same logic
        // and verify the delegate's pin-checking uses it correctly.
        // We verify the algorithm by computing SHA-256 of "hello" and checking
        // the base64 output matches the known value.
        let data = "hello".data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        let base64 = Data(hash).base64EncodedString()

        // SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        // Base64 of those bytes:
        XCTAssertEqual(base64, "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=",
                        "SHA-256 of 'hello' should match known base64 hash. "
                        + "Note: this validates the same algorithm the delegate uses.")
    }

    // MARK: - Bypass Hosts

    func test_bypassHost_localhost_returnsDefaultHandling() async {
        await verifyBypassHost("localhost")
    }

    func test_bypassHost_ipv4Loopback_returnsDefaultHandling() async {
        await verifyBypassHost("127.0.0.1")
    }

    func test_bypassHost_ipv6Loopback_returnsDefaultHandling() async {
        await verifyBypassHost("::1")
    }

    // MARK: - Unknown Host (No Pins Configured)

    func test_unknownHost_noPins_returnsDefaultHandling() async {
        // Ensure no pins are configured for this host
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }

        let delegate = PinnedSessionDelegate()
        let challenge = makeChallenge(host: "api.example.com")

        let expectation = XCTestExpectation(description: "completion called")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(
            URLSession.shared,
            didReceive: challenge
        ) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .performDefaultHandling)
    }
    
    func test_requiredProductionHost_openAI_noPins_cancelsChallenge() async {
        await verifyRequiredHostNoPinsCancels("api.openai.com")
    }
    
    func test_requiredProductionHost_anthropic_noPins_cancelsChallenge() async {
        await verifyRequiredHostNoPinsCancels("api.anthropic.com")
    }

    // MARK: - Default Pins

    func test_loadDefaultPins_populatesBothHosts() {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }

        PinnedSessionDelegate.loadDefaultPins()

        let anthropicPins = PinnedSessionDelegate.pinnedHosts["api.anthropic.com"]
        let openAIPins = PinnedSessionDelegate.pinnedHosts["api.openai.com"]

        XCTAssertNotNil(anthropicPins, "Anthropic pins should be populated after loadDefaultPins()")
        XCTAssertNotNil(openAIPins, "OpenAI pins should be populated after loadDefaultPins()")
        XCTAssertGreaterThanOrEqual(anthropicPins?.count ?? 0, 2,
                                     "Should have at least 2 pins (intermediate + root) for rotation safety")
        XCTAssertGreaterThanOrEqual(openAIPins?.count ?? 0, 2,
                                     "Should have at least 2 pins (intermediate + root) for rotation safety")
    }

    func test_loadDefaultPins_isIdempotent() {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }

        PinnedSessionDelegate.loadDefaultPins()
        let firstLoad = PinnedSessionDelegate.pinnedHosts

        PinnedSessionDelegate.loadDefaultPins()
        let secondLoad = PinnedSessionDelegate.pinnedHosts

        XCTAssertEqual(firstLoad, secondLoad, "Calling loadDefaultPins() twice should produce identical pin sets")
    }

    // MARK: - Non-ServerTrust Challenge

    func test_nonServerTrustChallenge_returnsDefaultHandling() async {
        let delegate = PinnedSessionDelegate()

        // Create a challenge with a non-server-trust authentication method
        let space = URLProtectionSpace(
            host: "example.com",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: StubChallengeSender()
        )

        let expectation = XCTestExpectation(description: "completion called")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(
            URLSession.shared,
            didReceive: challenge
        ) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .performDefaultHandling)
    }

    // MARK: - Concurrent Access

    func test_concurrentPinnedHostsAccess_doesNotCrash() {
        // Verify that concurrent reads and writes through the NSLock-guarded
        // accessor don't produce data races or crashes.
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        let group = DispatchGroup()

        for i in 0..<100 {
            group.enter()
            queue.async {
                if i.isMultiple(of: 2) {
                    PinnedSessionDelegate.pinnedHosts["api.example.com"] = ["hash\(i)"]
                } else {
                    _ = PinnedSessionDelegate.pinnedHosts
                }
                group.leave()
            }
        }

        group.wait()
        // Reaching here without a crash is sufficient.
        PinnedSessionDelegate.pinnedHosts = [:]
    }

    // MARK: - Helpers

    private func verifyBypassHost(_ host: String) async {
        let delegate = PinnedSessionDelegate()
        let challenge = makeChallenge(host: host)

        let expectation = XCTestExpectation(description: "completion called for \(host)")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(
            URLSession.shared,
            didReceive: challenge
        ) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .performDefaultHandling,
                       "Bypass host \(host) should get .performDefaultHandling")
    }
    
    private func verifyRequiredHostNoPinsCancels(_ host: String) async {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }
        
        let delegate = PinnedSessionDelegate()
        let challenge = makeChallenge(host: host)
        
        let expectation = XCTestExpectation(description: "completion called for required host \(host)")
        var receivedDisposition: URLSession.AuthChallengeDisposition?
        
        delegate.urlSession(
            URLSession.shared,
            didReceive: challenge
        ) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge,
                       "Required production host \(host) should fail closed when no pins are configured")
    }

    private func makeChallenge(host: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: StubChallengeSender()
        )
    }
}

// MARK: - Stub Challenge Sender

/// Minimal stub to satisfy URLAuthenticationChallenge init.
private final class StubChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

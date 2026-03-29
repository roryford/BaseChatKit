import Foundation

/// A `URLProtocol` subclass that intercepts HTTP requests and returns
/// canned responses configured per-URL.
///
/// Supports three response modes:
/// - **Immediate**: returns a single `Data` blob with a status code.
/// - **SSE (chunked)**: delivers data in chunks, simulating a Server-Sent Events stream.
/// - **Error**: fails the request with a `URLError`.
///
/// ## Usage
/// ```swift
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
///
/// MockURLProtocol.reset()
/// MockURLProtocol.stub(
///     url: someURL,
///     response: .sse(chunks: [...], statusCode: 200)
/// )
/// ```
public final class MockURLProtocol: URLProtocol {

    // MARK: - Stub Configuration

    /// Describes how a stubbed URL should respond.
    public enum StubbedResponse: @unchecked Sendable {
        /// Return data immediately with the given HTTP status code.
        case immediate(data: Data, statusCode: Int)
        /// Return data in chunks (simulating SSE), with a brief delay between each.
        case sse(chunks: [Data], statusCode: Int)
        /// Return a URL error (e.g. connection lost).
        case error(Error)
    }

    /// Thread-safe storage for stubs keyed by absolute URL string.
    private static let lock = NSLock()
    private static var stubs: [String: StubbedResponse] = [:]

    /// Registers a canned response for a URL.
    public static func stub(url: URL, response: StubbedResponse) {
        lock.lock()
        defer { lock.unlock() }
        stubs[url.absoluteString] = response
    }

    /// Removes all registered stubs.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll()
    }

    /// Finds a stub matching the URL — tries exact match first, then path-contains match.
    private static func findStub(for url: URL) -> StubbedResponse? {
        lock.lock()
        defer { lock.unlock() }

        // Exact match.
        if let stub = stubs[url.absoluteString] {
            return stub
        }

        // Path-contains match: the stub URL path is contained in the request URL path.
        // Handles cases like trailing slash differences or query parameters.
        let requestPath = url.absoluteString
        for (stubURL, stub) in stubs {
            if requestPath.hasPrefix(stubURL) || stubURL.hasPrefix(requestPath) {
                return stub
            }
        }

        // If only one stub is registered, use it as a catch-all (common in tests).
        if stubs.count == 1 {
            return stubs.values.first
        }

        return nil
    }

    // MARK: - URLProtocol Overrides

    public override class func canInit(with request: URLRequest) -> Bool {
        // Intercept all requests when any stubs are registered.
        lock.lock()
        defer { lock.unlock() }
        return !stubs.isEmpty
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        guard let url = request.url,
              let stub = Self.findStub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch stub {
        case .immediate(let data, let statusCode):
            deliverResponse(statusCode: statusCode, data: data)

        case .sse(let chunks, let statusCode):
            deliverSSEResponse(statusCode: statusCode, chunks: chunks)

        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    public override func stopLoading() {
        // Nothing to clean up for synchronous stubs.
    }

    // MARK: - Response Delivery

    private func deliverResponse(statusCode: Int, data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func deliverSSEResponse(statusCode: Int, chunks: [Data]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

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
        /// Return data immediately with the given HTTP status code and optional extra headers.
        case immediate(data: Data, statusCode: Int, headers: [String: String] = [:])
        /// Return data in chunks (simulating SSE), with a brief delay between each.
        case sse(chunks: [Data], statusCode: Int)
        /// Return data in chunks asynchronously — each chunk is delivered on a background
        /// thread with a small delay, allowing consumers to cancel between chunks.
        case asyncSSE(chunks: [Data], chunkDelay: TimeInterval = 0.005, statusCode: Int)
        /// Return a URL error (e.g. connection lost).
        case error(Error)
    }

    /// Thread-safe storage for stubs keyed by absolute URL string.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [String: StubbedResponse] = [:]
    /// Ordered sequences of responses: each call pops the first element.
    /// When exhausted, falls back to the single-response stub (if any).
    private nonisolated(unsafe) static var stubSequences: [String: [StubbedResponse]] = [:]
    private nonisolated(unsafe) static var _capturedRequests: [URLRequest] = []

    /// All requests intercepted since the last `reset()` call, in order.
    public static var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _capturedRequests
    }

    /// Registers a canned response for a URL.
    public static func stub(url: URL, response: StubbedResponse) {
        lock.lock()
        defer { lock.unlock() }
        stubs[url.absoluteString] = response
    }

    /// Registers an ordered sequence of responses for a URL.
    ///
    /// Each request pops the first element. When the sequence is exhausted,
    /// falls back to the single-response stub registered via ``stub(url:response:)``.
    public static func stubSequence(url: URL, responses: [StubbedResponse]) {
        lock.lock()
        defer { lock.unlock() }
        stubSequences[url.absoluteString] = responses
    }

    /// Removes the stub (and any sequence) registered for a single URL.
    ///
    /// Prefer this over ``reset()`` in test teardown — it cleans up only the
    /// current test's stub without clearing stubs registered by other suites
    /// that may be running concurrently.
    public static func unstub(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeValue(forKey: url.absoluteString)
        stubSequences.removeValue(forKey: url.absoluteString)
    }

    /// Removes all registered stubs and captured requests.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll()
        stubSequences.removeAll()
        _capturedRequests.removeAll()
    }

    /// Finds a stub matching the URL — tries sequence first, then exact match, then path-contains.
    private static func findStub(for url: URL) -> StubbedResponse? {
        lock.lock()
        defer { lock.unlock() }

        // Sequence match: pop the first element if available.
        let key = url.absoluteString
        if var seq = stubSequences[key], !seq.isEmpty {
            let next = seq.removeFirst()
            stubSequences[key] = seq
            return next
        }

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

    // MARK: - Instance State

    private var asyncDeliveryItem: DispatchWorkItem?

    // MARK: - URLProtocol Overrides

    public override class func canInit(with request: URLRequest) -> Bool {
        // Intercept all requests when any stubs or non-exhausted sequences are registered.
        lock.lock()
        defer { lock.unlock() }
        let hasActiveSequences = stubSequences.values.contains { !$0.isEmpty }
        return !stubs.isEmpty || hasActiveSequences
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        // Capture every intercepted request for later inspection.
        Self.lock.lock()
        Self._capturedRequests.append(request)
        Self.lock.unlock()

        guard let url = request.url,
              let stub = Self.findStub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch stub {
        case .immediate(let data, let statusCode, let extraHeaders):
            deliverResponse(statusCode: statusCode, data: data, extraHeaders: extraHeaders)

        case .sse(let chunks, let statusCode):
            deliverSSEResponse(statusCode: statusCode, chunks: chunks)

        case .asyncSSE(let chunks, let chunkDelay, let statusCode):
            deliverAsyncSSEResponse(statusCode: statusCode, chunks: chunks, chunkDelay: chunkDelay)

        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    public override func stopLoading() {
        asyncDeliveryItem?.cancel()
        asyncDeliveryItem = nil
    }

    // MARK: - Response Delivery

    private func deliverResponse(statusCode: Int, data: Data, extraHeaders: [String: String] = [:]) {
        var headers = ["Content-Type": "text/event-stream"]
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
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

    /// Delivers chunks on a background thread with a small delay between each,
    /// so that async consumers have a real opportunity to cancel mid-stream.
    private func deliverAsyncSSEResponse(statusCode: Int, chunks: [Data], chunkDelay: TimeInterval) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let client = self.client
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem {
            for chunk in chunks {
                if workItem.isCancelled { break }
                Thread.sleep(forTimeInterval: chunkDelay)
                if workItem.isCancelled { break }
                client?.urlProtocol(self, didLoad: chunk)
            }
            if !workItem.isCancelled {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        asyncDeliveryItem = workItem
        DispatchQueue.global(qos: .default).async(execute: workItem)
    }
}

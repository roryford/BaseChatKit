import Foundation
import BaseChatCore

/// Configurable mock discovery service for testing.
///
/// Emits canned server lists and tracks calls.
public final class MockServerDiscoveryService: ServerDiscoveryService, @unchecked Sendable {

    nonisolated(unsafe) public var startCallCount = 0
    nonisolated(unsafe) public var stopCallCount = 0
    nonisolated(unsafe) public var probeCallCount = 0

    /// Servers to emit when discovery starts.
    nonisolated(unsafe) public var serversToEmit: [DiscoveredServer] = []

    /// Server to return from `probe(host:port:)`.
    nonisolated(unsafe) public var probeResult: DiscoveredServer?

    private let continuation: AsyncStream<[DiscoveredServer]>.Continuation
    public let discoveredServers: AsyncStream<[DiscoveredServer]>

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: [DiscoveredServer].self)
        self.discoveredServers = stream
        self.continuation = continuation
    }

    public func startDiscovery() async {
        startCallCount += 1
        if !serversToEmit.isEmpty {
            continuation.yield(serversToEmit)
        }
    }

    public func stopDiscovery() {
        stopCallCount += 1
    }

    public func probe(host: String, port: Int) async -> DiscoveredServer? {
        probeCallCount += 1
        return probeResult
    }

    /// Manually emit a server update (for testing incremental discovery).
    public func emit(_ servers: [DiscoveredServer]) {
        continuation.yield(servers)
    }

    /// Resets all state.
    public func reset() {
        startCallCount = 0
        stopCallCount = 0
        probeCallCount = 0
        serversToEmit = []
        probeResult = nil
    }
}

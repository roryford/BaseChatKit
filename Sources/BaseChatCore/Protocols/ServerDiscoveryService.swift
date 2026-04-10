import Foundation

/// Discovers running inference servers on the local network.
///
/// Implementations scan known ports and probe health endpoints to find
/// Ollama, LM Studio, and other OpenAI-compatible servers.
/// The protocol lives in BaseChatCore so that BaseChatUI can consume
/// discovered servers without importing BaseChatBackends.
///
/// ## Thread Safety
///
/// The protocol requires `AnyObject & Sendable`. The built-in conformer
/// (`BonjourDiscoveryService`) is an `actor`, which provides full
/// isolation. Custom conformers that use a class must mark `@unchecked
/// Sendable` and guard mutable state, since ``startDiscovery()`` and
/// ``stopDiscovery()`` may be called from different concurrency contexts
/// (e.g. a SwiftUI view's `.task` modifier vs. a button action).
/// ``discoveredServers`` is an `AsyncStream` and is safe to consume from
/// any task.
public protocol ServerDiscoveryService: AnyObject, Sendable {
    /// Begins scanning for servers. Results stream via ``discoveredServers``.
    func startDiscovery() async

    /// Stops any active scanning.
    func stopDiscovery()

    /// A stream of discovered servers, updated as servers are found or lost.
    var discoveredServers: AsyncStream<[DiscoveredServer]> { get }

    /// Probes a specific host:port and returns a server if reachable.
    func probe(host: String, port: Int) async -> DiscoveredServer?
}

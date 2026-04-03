import Foundation

/// Discovers running inference servers on the local network.
///
/// Implementations scan known ports and probe health endpoints to find
/// Ollama, KoboldCpp, LM Studio, and other OpenAI-compatible servers.
/// The protocol lives in BaseChatCore so that BaseChatUI can consume
/// discovered servers without importing BaseChatBackends.
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

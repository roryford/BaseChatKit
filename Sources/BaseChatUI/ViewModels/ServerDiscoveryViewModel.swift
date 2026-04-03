import Foundation
import Observation
import SwiftData
import BaseChatCore

/// Manages server discovery state for the UI.
///
/// Wraps a `ServerDiscoveryService` and exposes discovered servers,
/// model selection, and endpoint creation for the discovery sheet.
@Observable
@MainActor
public final class ServerDiscoveryViewModel {

    // MARK: - State

    /// Servers discovered on the local network.
    public private(set) var discoveredServers: [DiscoveredServer] = []

    /// Whether discovery is currently scanning.
    public private(set) var isScanning = false

    /// The server selected by the user.
    public var selectedServer: DiscoveredServer?

    /// Error message for display.
    public var errorMessage: String?

    /// Manual host entry text.
    public var manualHost: String = ""

    /// Manual port entry text.
    public var manualPort: String = ""

    // MARK: - Init

    private let discoveryService: ServerDiscoveryService

    public init(discoveryService: ServerDiscoveryService) {
        self.discoveryService = discoveryService
    }

    // MARK: - Discovery Lifecycle

    private var discoveryTask: Task<Void, Never>?

    /// Starts scanning for local servers.
    public func startDiscovery() {
        isScanning = true

        // Subscribe to the stream first so the continuation is installed
        // before startDiscovery yields results. NetworkDiscoveryService's
        // `discoveredServers` creates a new stream on each access and
        // installs its continuation via a Task — we capture the stream
        // eagerly so the continuation is ready when discovery emits.
        let serverStream = discoveryService.discoveredServers

        discoveryTask = Task { [weak self] in
            guard let self else { return }

            // Give the stream's continuation-installation task a chance to run
            // before we start probing servers.
            await Task.yield()

            // Start scanning concurrently while we listen for results.
            Task { [weak self] in
                await self?.discoveryService.startDiscovery()
            }

            for await servers in serverStream {
                guard !Task.isCancelled else { break }
                self.discoveredServers = servers
            }
            self.isScanning = false
        }
    }

    /// Stops scanning.
    public func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryService.stopDiscovery()
        isScanning = false
    }

    // MARK: - Manual Probe

    /// Probes a manually entered host:port.
    public func probeManualEntry() async {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMessage = "Enter a hostname or IP address."
            return
        }

        let port = Int(manualPort) ?? 11434
        errorMessage = nil

        if let server = await discoveryService.probe(host: host, port: port) {
            if !discoveredServers.contains(where: { $0.host == server.host && $0.port == server.port }) {
                discoveredServers.append(server)
            }
            selectedServer = server
        } else {
            errorMessage = "No server found at \(host):\(port)"
        }
    }

    // MARK: - Endpoint Creation

    /// Creates a persisted `APIEndpoint` from a discovered server and model.
    @discardableResult
    public func createEndpoint(
        server: DiscoveredServer,
        model: RemoteModelInfo,
        modelContext: ModelContext
    ) -> APIEndpoint {
        let endpoint = APIEndpoint(
            name: "\(server.displayName) — \(model.name)",
            provider: server.apiProvider,
            baseURL: server.baseURL?.absoluteString,
            modelName: model.name
        )
        modelContext.insert(endpoint)
        try? modelContext.save()
        return endpoint
    }
}

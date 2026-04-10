import Foundation
import Network
import os
import BaseChatCore

/// Discovers local inference servers via Bonjour/mDNS using `NWBrowser`.
///
/// Scans for `_ollama._tcp` services and publishes each as a ``DiscoveredServer``
/// candidate. Port-probing is performed via HTTP to fetch the model list and
/// confirm the server is healthy before yielding.
///
/// ## Info.plist requirement (consumer responsibility)
///
/// The **consuming app** must add `NSLocalNetworkUsageDescription` to its
/// `Info.plist`; otherwise the system will silently block Bonjour browsing.
/// BaseChatKit does not add this key automatically.
///
/// ```xml
/// <key>NSLocalNetworkUsageDescription</key>
/// <string>Used to discover Ollama servers on your local network.</string>
/// ```
///
/// Usage:
/// ```swift
/// let discovery = BonjourDiscoveryService()
/// let stream = discovery.discoveredServers
/// Task { await discovery.startDiscovery() }
/// for await servers in stream {
///     print(servers)
/// }
/// ```
public actor BonjourDiscoveryService: ServerDiscoveryService {

    // MARK: - Types

    private struct ServiceDefinition {
        let type: String      // e.g. "_ollama._tcp"
        let serverType: ServerType
        let displayName: String
        let healthPath: String
        let defaultPort: Int
    }

    private static let serviceDefinitions: [ServiceDefinition] = [
        ServiceDefinition(
            type: "_ollama._tcp",
            serverType: .ollama,
            displayName: "Ollama",
            healthPath: "/api/tags",
            defaultPort: 11434
        ),
    ]

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "discovery"
    )

    // MARK: - State (actor-isolated)

    private let probeSession: URLSession
    private var continuation: AsyncStream<[DiscoveredServer]>.Continuation?
    private var resolvedServers: [String: DiscoveredServer] = [:]  // key: "host:port"
    private var endpointToKey: [NWEndpoint: String] = [:]
    private var isRunning = false

    // Browsers must be stoppable from nonisolated context — use a lock-protected store.
    private let browsersLock = OSAllocatedUnfairLock(initialState: [NWBrowser]())

    // MARK: - Init

    /// Creates a BonjourDiscoveryService.
    ///
    /// - Parameter urlSession: Custom session for health probing in tests.
    public init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.probeSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            self.probeSession = URLSession(configuration: config)
        }
    }

    // MARK: - ServerDiscoveryService

    public nonisolated var discoveredServers: AsyncStream<[DiscoveredServer]> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    private func setContinuation(_ cont: AsyncStream<[DiscoveredServer]>.Continuation) {
        continuation = cont
        // Yield current snapshot so late subscribers don't miss already-resolved servers.
        if !resolvedServers.isEmpty {
            cont.yield(Array(resolvedServers.values))
        }
    }

    public func startDiscovery() async {
        guard !isRunning else { return }
        isRunning = true

        Self.logger.info("BonjourDiscoveryService starting mDNS scan")

        for definition in Self.serviceDefinitions {
            startBrowser(for: definition)
        }
    }

    public nonisolated func stopDiscovery() {
        browsersLock.withLock { browsers in
            browsers.forEach { $0.cancel() }
            browsers.removeAll()
        }
        Task { await self.markStopped() }
        Self.logger.info("BonjourDiscoveryService stopped")
    }

    private func markStopped() {
        isRunning = false
    }

    public func probe(host: String, port: Int) async -> DiscoveredServer? {
        if let def = Self.serviceDefinitions.first(where: { $0.defaultPort == port }) {
            return await probeServer(host: host, port: port, definition: def)
        }
        return await probeOpenAICompatible(host: host, port: port)
    }

    // MARK: - Browser Management

    private func startBrowser(for definition: ServiceDefinition) {
        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: definition.type, domain: "local."), using: params)

        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Self.logger.error("NWBrowser failed for \(definition.type, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }

        browser.browseResultsChangedHandler = { [definition] _, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    Task { await self.resolveEndpoint(result.endpoint, definition: definition) }
                case .removed(let result):
                    Task { await self.removeEndpoint(result.endpoint) }
                default:
                    break
                }
            }
        }

        browsersLock.withLock { $0.append(browser) }
        browser.start(queue: .global(qos: .utility))
    }

    // MARK: - Endpoint Resolution

    private func resolveEndpoint(_ endpoint: NWEndpoint, definition: ServiceDefinition) async {
        guard case .service = endpoint else { return }

        let resolved = await resolveNWEndpoint(endpoint)
        guard let (host, port) = resolved else { return }

        if let server = await probeServer(host: host, port: port, definition: definition) {
            publishServer(server, endpoint: endpoint)
        }
    }

    private func removeEndpoint(_ endpoint: NWEndpoint) {
        guard let key = endpointToKey.removeValue(forKey: endpoint) else { return }
        resolvedServers.removeValue(forKey: key)
        continuation?.yield(Array(resolvedServers.values))
    }

    /// Resolves an NWEndpoint to a (host, port) pair by briefly connecting.
    private func resolveNWEndpoint(_ endpoint: NWEndpoint) async -> (String, Int)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(String, Int)?, Never>) in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let resumedLock = OSAllocatedUnfairLock(initialState: false)

            let resume: @Sendable ((String, Int)?) -> Void = { value in
                let shouldResume = resumedLock.withLock { state -> Bool in
                    guard !state else { return false }
                    state = true
                    return true
                }
                if shouldResume { continuation.resume(returning: value) }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let path = connection.currentPath,
                       case .hostPort(let h, let p) = path.remoteEndpoint {
                        resume(("\(h)", Int(p.rawValue)))
                    } else {
                        resume(nil)
                    }
                    connection.cancel()
                case .failed, .cancelled:
                    resume(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            Task {
                try? await Task.sleep(for: .seconds(3))
                connection.cancel()
                resume(nil)
            }
        }
    }

    // MARK: - HTTP Probing

    private func probeServer(
        host: String,
        port: Int,
        definition: ServiceDefinition
    ) async -> DiscoveredServer? {
        guard let url = URL(string: "http://\(host):\(port)\(definition.healthPath)") else { return nil }
        do {
            let (data, response) = try await probeSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            let models = parseModels(data: data, serverType: definition.serverType)
            return DiscoveredServer(
                displayName: definition.displayName,
                host: host,
                port: port,
                serverType: definition.serverType,
                models: models
            )
        } catch {
            return nil
        }
    }

    private func probeOpenAICompatible(host: String, port: Int) async -> DiscoveredServer? {
        guard let url = URL(string: "http://\(host):\(port)/v1/models") else { return nil }
        do {
            let (data, response) = try await probeSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            let models = parseOpenAIModels(data: data)
            return DiscoveredServer(
                displayName: "Server (\(host):\(port))",
                host: host,
                port: port,
                serverType: .openAICompatible,
                models: models
            )
        } catch {
            return nil
        }
    }

    private func publishServer(_ server: DiscoveredServer, endpoint: NWEndpoint) {
        let key = "\(server.host):\(server.port)"
        endpointToKey[endpoint] = key
        resolvedServers[key] = server
        continuation?.yield(Array(resolvedServers.values))
    }

    // MARK: - Model Parsing

    private func parseModels(data: Data, serverType: ServerType) -> [RemoteModelInfo] {
        switch serverType {
        case .ollama: return parseOllamaModels(data: data)
        default: return parseOpenAIModels(data: data)
        }
    }

    private func parseOllamaModels(data: Data) -> [RemoteModelInfo] {
        struct Resp: Decodable {
            struct M: Decodable { let name: String; let size: Int64? }
            let models: [M]?
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data),
              let models = r.models else { return [] }
        return models.map { m in
            let parts = m.name.split(separator: ":", maxSplits: 1)
            return RemoteModelInfo(
                name: m.name,
                sizeBytes: m.size,
                quantization: parts.count > 1 ? String(parts[1]) : nil
            )
        }
    }

    private func parseOpenAIModels(data: Data) -> [RemoteModelInfo] {
        struct Resp: Decodable {
            struct M: Decodable { let id: String }
            let data: [M]?
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data),
              let models = r.data else { return [] }
        return models.map { RemoteModelInfo(id: $0.id, name: $0.id) }
    }
}

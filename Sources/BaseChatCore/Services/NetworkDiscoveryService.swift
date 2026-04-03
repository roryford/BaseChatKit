import Foundation
import os

/// Concrete implementation of ``ServerDiscoveryService`` that probes known
/// ports on localhost (and optionally user-provided hosts) via HTTP requests.
///
/// Known ports:
/// - **11434**: Ollama (`GET /api/tags`)
/// - **5001**: KoboldCpp (`GET /api/v1/model`)
/// - **1234**: LM Studio (`GET /v1/models`)
public actor NetworkDiscoveryService: ServerDiscoveryService {

    // MARK: - Known server definitions

    private struct ServerProbe {
        let port: Int
        let serverType: ServerType
        let displayName: String
        let healthPath: String
    }

    private static let knownServers: [ServerProbe] = [
        ServerProbe(port: 11434, serverType: .ollama, displayName: "Ollama", healthPath: "/api/tags"),
        ServerProbe(port: 5001, serverType: .koboldCpp, displayName: "KoboldCpp", healthPath: "/api/v1/model"),
        ServerProbe(port: 1234, serverType: .lmStudio, displayName: "LM Studio", healthPath: "/v1/models"),
    ]

    // MARK: - State

    private let session: URLSession
    private var continuation: AsyncStream<[DiscoveredServer]>.Continuation?
    private let scanningLock = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Init

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2
            config.timeoutIntervalForResource = 2
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - ServerDiscoveryService

    public nonisolated var discoveredServers: AsyncStream<[DiscoveredServer]> {
        // The stream is created lazily on first access. Because we're nonisolated
        // we build it via a detached task that hops into the actor.
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    public func startDiscovery() async {
        let alreadyScanning = scanningLock.withLock { state -> Bool in
            if state { return true }
            state = true
            return false
        }
        guard !alreadyScanning else { return }

        let hosts = ["localhost"]
        var servers: [DiscoveredServer] = []

        for host in hosts {
            for knownServer in Self.knownServers {
                if let server = await probeKnownServer(knownServer, host: host) {
                    servers.append(server)
                }
            }
        }

        continuation?.yield(servers)
        scanningLock.withLock { $0 = false }
    }

    public nonisolated func stopDiscovery() {
        scanningLock.withLock { $0 = false }
    }

    public func probe(host: String, port: Int) async -> DiscoveredServer? {
        // Check if this matches a known server port
        if let known = Self.knownServers.first(where: { $0.port == port }) {
            return await probeKnownServer(known, host: host)
        }

        // For unknown ports, try OpenAI-compatible /v1/models
        return await probeOpenAICompatible(host: host, port: port)
    }

    // MARK: - Private

    private func setContinuation(_ c: AsyncStream<[DiscoveredServer]>.Continuation) {
        self.continuation = c
    }

    private func probeKnownServer(_ server: ServerProbe, host: String) async -> DiscoveredServer? {
        guard let url = URL(string: "http://\(host):\(server.port)\(server.healthPath)") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            let models = parseModels(data: data, serverType: server.serverType)
            return DiscoveredServer(
                displayName: server.displayName,
                host: host,
                port: server.port,
                serverType: server.serverType,
                models: models
            )
        } catch {
            return nil
        }
    }

    private func probeOpenAICompatible(host: String, port: Int) async -> DiscoveredServer? {
        guard let url = URL(string: "http://\(host):\(port)/v1/models") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

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

    // MARK: - Response parsing

    private func parseModels(data: Data, serverType: ServerType) -> [RemoteModelInfo] {
        switch serverType {
        case .ollama:
            return parseOllamaModels(data: data)
        case .koboldCpp:
            return parseKoboldCppModel(data: data)
        case .lmStudio:
            return parseOpenAIModels(data: data)
        case .openAICompatible:
            return parseOpenAIModels(data: data)
        }
    }

    /// Parses Ollama's `GET /api/tags` response: `{"models":[{"name":"...","size":...}]}`
    private func parseOllamaModels(data: Data) -> [RemoteModelInfo] {
        struct OllamaResponse: Decodable {
            struct Model: Decodable {
                let name: String
                let size: Int64?
            }
            let models: [Model]?
        }

        guard let response = try? JSONDecoder().decode(OllamaResponse.self, from: data),
              let models = response.models else {
            return []
        }

        return models.map { model in
            // Ollama names look like "llama3.2:7b-q4_0" — split on ":" for quantization
            let parts = model.name.split(separator: ":", maxSplits: 1)
            let quantization = parts.count > 1 ? String(parts[1]) : nil
            return RemoteModelInfo(
                name: model.name,
                sizeBytes: model.size,
                quantization: quantization
            )
        }
    }

    /// Parses KoboldCpp's `GET /api/v1/model` response: `{"result":"modelname"}`
    private func parseKoboldCppModel(data: Data) -> [RemoteModelInfo] {
        struct KoboldResponse: Decodable {
            let result: String?
        }

        guard let response = try? JSONDecoder().decode(KoboldResponse.self, from: data),
              let modelName = response.result, !modelName.isEmpty else {
            return []
        }

        return [RemoteModelInfo(name: modelName)]
    }

    /// Parses OpenAI-compatible `GET /v1/models` response: `{"data":[{"id":"..."}]}`
    private func parseOpenAIModels(data: Data) -> [RemoteModelInfo] {
        struct OpenAIResponse: Decodable {
            struct Model: Decodable {
                let id: String
            }
            let data: [Model]?
        }

        guard let response = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
              let models = response.data else {
            return []
        }

        return models.map { RemoteModelInfo(id: $0.id, name: $0.id) }
    }
}

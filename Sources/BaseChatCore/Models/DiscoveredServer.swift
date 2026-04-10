import Foundation

/// The type of inference server discovered on the network.
public enum ServerType: String, Sendable, Codable {
    case ollama
    case lmStudio
    case openAICompatible
}

/// A model available on a remote inference server.
public struct RemoteModelInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let sizeBytes: Int64?
    public let quantization: String?
    public let familyTag: String?

    public init(id: String? = nil, name: String, sizeBytes: Int64? = nil, quantization: String? = nil, familyTag: String? = nil) {
        self.id = id ?? name
        self.name = name
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.familyTag = familyTag
    }
}

/// Represents an inference server found on the local network.
public struct DiscoveredServer: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let displayName: String
    public let host: String
    public let port: Int
    public let serverType: ServerType
    public var models: [RemoteModelInfo]
    public let lastSeen: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int,
        serverType: ServerType,
        models: [RemoteModelInfo] = [],
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.serverType = serverType
        self.models = models
        self.lastSeen = lastSeen
    }

    /// The base URL for API requests to this server.
    public var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    /// The APIProvider that corresponds to this server type.
    public var apiProvider: APIProvider {
        switch serverType {
        case .ollama: return .ollama
        case .lmStudio: return .lmStudio
        case .openAICompatible: return .custom
        }
    }
}

import Foundation
import SwiftData

/// The cloud API provider type.
public enum APIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI"
    case claude = "Claude"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case custom = "Custom"

    public var id: String { rawValue }

    /// Default base URL for this provider.
    public var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com"
        case .claude: return "https://api.anthropic.com"
        case .ollama: return "http://localhost:11434"
        case .lmStudio: return "http://localhost:1234"
        case .custom: return "https://"
        }
    }

    /// Whether this provider requires an API key.
    public var requiresAPIKey: Bool {
        switch self {
        case .openAI, .claude, .custom: return true
        case .ollama, .lmStudio: return false
        }
    }

    /// Default model name for this provider.
    public var defaultModelName: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .claude: return "claude-sonnet-4-20250514"
        case .ollama: return "llama3.2"
        case .lmStudio: return "local-model"
        case .custom: return "model"
        }
    }
}

/// A configured cloud API endpoint persisted via SwiftData.
///
/// The API key is NOT stored here — it lives in the Keychain, referenced
/// by this endpoint's `id` as the Keychain account identifier.
@Model
public final class APIEndpoint {
    public var id: UUID
    public var name: String
    public var providerRawValue: String
    public var baseURL: String
    public var modelName: String
    public var createdAt: Date
    public var isEnabled: Bool

    public init(
        name: String,
        provider: APIProvider,
        baseURL: String? = nil,
        modelName: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.providerRawValue = provider.rawValue
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.modelName = modelName ?? provider.defaultModelName
        self.createdAt = Date()
        self.isEnabled = true
    }

    /// The provider type as an enum.
    public var provider: APIProvider {
        get { APIProvider(rawValue: providerRawValue) ?? .custom }
        set { providerRawValue = newValue.rawValue }
    }

    /// The Keychain account identifier for this endpoint's API key.
    public var keychainAccount: String {
        id.uuidString
    }

    /// Retrieves the API key from the Keychain.
    public var apiKey: String? {
        KeychainService.retrieve(account: keychainAccount)
    }

    /// Stores an API key in the Keychain for this endpoint.
    @discardableResult
    public func setAPIKey(_ key: String) -> Bool {
        KeychainService.store(key: key, account: keychainAccount)
    }

    /// Deletes the API key from the Keychain.
    public func deleteAPIKey() {
        KeychainService.delete(account: keychainAccount)
    }

    /// Validates the endpoint configuration.
    public var isValid: Bool {
        guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else {
            return false
        }

        // HTTPS required for remote endpoints
        if !isLocalhost(url) && url.scheme != "https" {
            return false
        }

        // API key required for providers that need one
        if provider.requiresAPIKey && (apiKey?.isEmpty ?? true) {
            return false
        }

        return true
    }

    /// Checks if the URL points to a local server.
    private func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

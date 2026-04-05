import Foundation
import SwiftData

/// Version 1 of the BaseChatKit SwiftData schema.
///
/// This is the baseline schema, formalising the initial set of `@Model` types.
/// No data transformation is required when migrating to this version — it is
/// the starting point for all future migrations.
///
/// ## Adding a new schema version
///
/// 1. Create `BaseChatSchemaV2` (or the next version) in a new file, e.g.
///    `BaseChatSchemaV2.swift`, following the same `VersionedSchema` pattern.
/// 2. List any renamed types as `typealias` inside the new enum, e.g.:
///    ```swift
///    typealias ChatSession = BaseChatSchemaV2.ChatSession
///    ```
/// 3. Add the new schema to `BaseChatMigrationPlan.schemas` (append to the array).
/// 4. Add a `MigrationStage` to `BaseChatMigrationPlan.stages`:
///    - Use `.lightweight(fromVersion:toVersion:)` if only new optional
///      attributes or renamed attributes are involved.
///    - Use `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` when
///      data transformation is required.
public enum BaseChatSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ChatMessage.self,
            ChatSession.self,
            SamplerPreset.self,
            APIEndpoint.self,
        ]
    }

    /// A single message in a chat conversation, persisted via SwiftData.
    ///
    /// Messages belong to a session (identified by `sessionID`).
    @Model
    public final class ChatMessage {
        public var id: UUID
        public var role: MessageRole
        public var content: String
        public var timestamp: Date
        public var sessionID: UUID

        /// Tokens used in the prompt for this response (cloud API backends only).
        public var promptTokens: Int?
        /// Tokens generated in this response (cloud API backends only).
        public var completionTokens: Int?

        public init(
            role: MessageRole,
            content: String,
            sessionID: UUID
        ) {
            self.id = UUID()
            self.role = role
            self.content = content
            self.timestamp = Date()
            self.sessionID = sessionID
        }
    }

    /// A chat session containing a sequence of messages with its own settings.
    ///
    /// Sessions hold per-session overrides for generation parameters. When an
    /// override is `nil`, the app falls back to global defaults from `SettingsService`.
    @Model
    public final class ChatSession {
        public var id: UUID
        public var title: String
        public var createdAt: Date
        public var updatedAt: Date

        /// Per-session system prompt.
        public var systemPrompt: String

        /// The UUID of the selected ModelInfo for this session.
        public var selectedModelID: UUID?

        /// The UUID of the selected APIEndpoint for this session.
        public var selectedEndpointID: UUID?

        // Per-session generation overrides (nil = use global default)
        public var temperature: Float?
        public var topP: Float?
        public var repeatPenalty: Float?

        /// Stored as PromptTemplate.rawValue; nil means auto-detect or global default.
        public var promptTemplateRawValue: String?

        /// User override for context window size; nil uses model default.
        public var contextSizeOverride: Int?

        /// Raw storage for CompressionMode. nil means .automatic.
        /// SwiftData lightweight migration handles this new optional column automatically.
        public var compressionModeRaw: String?

        /// Comma-separated UUID strings of pinned messages in this session.
        /// nil means no messages are pinned.
        public var pinnedMessageIDsRaw: String?

        public init(title: String = "New Chat") {
            self.id = UUID()
            self.title = title
            self.createdAt = Date()
            self.updatedAt = Date()
            self.systemPrompt = ""
        }

        /// The set of pinned message IDs for this session.
        ///
        /// Pinned messages are preserved during context compression regardless of age.
        /// Serialized as comma-separated UUID strings in ``pinnedMessageIDsRaw``.
        public var pinnedMessageIDs: Set<UUID> {
            get {
                guard let raw = pinnedMessageIDsRaw else { return [] }
                return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            }
            set {
                pinnedMessageIDsRaw = newValue.isEmpty ? nil : newValue.map(\.uuidString).joined(separator: ",")
            }
        }

        /// The compression mode for this session.
        ///
        /// Defaults to `.automatic` when no value is stored.
        public var compressionMode: CompressionMode {
            get { compressionModeRaw.flatMap(CompressionMode.init(rawValue:)) ?? .automatic }
            set { compressionModeRaw = newValue.rawValue }
        }

        /// Convenience to get/set the prompt template as a `PromptTemplate` enum.
        public var promptTemplate: PromptTemplate? {
            get {
                guard let raw = promptTemplateRawValue else { return nil }
                return PromptTemplate(rawValue: raw)
            }
            set {
                promptTemplateRawValue = newValue?.rawValue
            }
        }
    }

    /// A saved set of generation parameters that can be applied to any session.
    @Model
    public final class SamplerPreset {
        public var id: UUID
        public var name: String
        public var temperature: Float
        public var topP: Float
        public var repeatPenalty: Float
        public var createdAt: Date

        public init(name: String, temperature: Float = 0.7, topP: Float = 0.9, repeatPenalty: Float = 1.1) {
            self.id = UUID()
            self.name = name
            self.temperature = temperature
            self.topP = topP
            self.repeatPenalty = repeatPenalty
            self.createdAt = Date()
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
}

/// The migration plan for BaseChatKit's SwiftData store.
///
/// `BaseChatMigrationPlan` lists every schema version in chronological order
/// and the migration stages that connect them.  Apps should pass this type to
/// `ModelContainerFactory.makeContainer()` (or directly to `ModelContainer`)
/// so that the store is upgraded automatically rather than deleted and
/// recreated on schema changes.
///
/// The plan currently contains a single schema version (`BaseChatSchemaV1`)
/// with no migration stages, which simply establishes V1 as the baseline.
/// Future versions append both a schema *and* a matching `MigrationStage`.
public enum BaseChatMigrationPlan: SchemaMigrationPlan {
    /// All schema versions in oldest-to-newest order.
    public static var schemas: [any VersionedSchema.Type] {
        [BaseChatSchemaV1.self]
    }

    /// Migration stages between consecutive schema versions.
    ///
    /// Empty for V1 — there is no prior version to migrate from.
    public static var stages: [MigrationStage] { [] }
}

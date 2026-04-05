import Foundation
import SwiftData

/// Version 1 of the BaseChatKit SwiftData schema.
///
/// This is the baseline schema, formalising the initial set of `@Model` types.
/// No data transformation is required when migrating to this version — it is
/// the starting point for all future migrations.
///
/// Each nested `@Model` class is a **frozen snapshot** of the model as it
/// existed at V1. The live types used throughout the codebase are typealiases
/// pointing at these nested types, so `BaseChatSchemaV1` will never silently
/// reflect mutations made for a future schema version.
///
/// ## Adding a new schema version
///
/// 1. Create `BaseChatSchemaV2` (or the next version) in a new file, e.g.
///    `BaseChatSchemaV2.swift`, following the same `VersionedSchema` pattern.
/// 2. Copy the nested model classes you need to change into `BaseChatSchemaV2`
///    and apply your mutations there.
/// 3. Update the package-level typealiases in `BaseChatSchema.swift` to point
///    at the V2 nested types.
/// 4. Add the new schema to `BaseChatMigrationPlan.schemas` (append to the array).
/// 5. Add a `MigrationStage` to `BaseChatMigrationPlan.stages`:
///    - Use `.lightweight(fromVersion:toVersion:)` if only new optional
///      attributes or renamed attributes are involved.
///    - Use `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` when
///      data transformation is required.
public enum BaseChatSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [ChatMessage.self, ChatSession.self, SamplerPreset.self, APIEndpoint.self]
    }

    // MARK: - Frozen model snapshots

    /// Frozen V1 snapshot of `ChatMessage`.
    @Model
    public final class ChatMessage {
        public var id: UUID
        public var role: MessageRole
        public var content: String
        public var timestamp: Date
        public var sessionID: UUID
        public var promptTokens: Int?
        public var completionTokens: Int?

        public init(role: MessageRole, content: String, sessionID: UUID) {
            self.id = UUID()
            self.role = role
            self.content = content
            self.timestamp = Date()
            self.sessionID = sessionID
        }
    }

    /// Frozen V1 snapshot of `ChatSession`.
    @Model
    public final class ChatSession {
        public var id: UUID
        public var title: String
        public var createdAt: Date
        public var updatedAt: Date
        public var systemPrompt: String
        public var selectedModelID: UUID?
        public var selectedEndpointID: UUID?
        public var temperature: Float?
        public var topP: Float?
        public var repeatPenalty: Float?
        public var promptTemplateRawValue: String?
        public var contextSizeOverride: Int?
        public var compressionModeRaw: String?
        public var pinnedMessageIDsRaw: String?

        public init(title: String = "New Chat") {
            self.id = UUID()
            self.title = title
            self.createdAt = Date()
            self.updatedAt = Date()
            self.systemPrompt = ""
        }

        public var pinnedMessageIDs: Set<UUID> {
            get {
                guard let raw = pinnedMessageIDsRaw else { return [] }
                return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            }
            set {
                pinnedMessageIDsRaw = newValue.isEmpty ? nil : newValue.map(\.uuidString).joined(separator: ",")
            }
        }

        public var compressionMode: CompressionMode {
            get { compressionModeRaw.flatMap(CompressionMode.init(rawValue:)) ?? .automatic }
            set { compressionModeRaw = newValue.rawValue }
        }

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

    /// Frozen V1 snapshot of `SamplerPreset`.
    @Model
    public final class SamplerPreset {
        public var id: UUID
        public var name: String
        public var temperature: Float
        public var topP: Float
        public var repeatPenalty: Float
        public var createdAt: Date

        public init(
            name: String,
            temperature: Float = 0.7,
            topP: Float = 0.9,
            repeatPenalty: Float = 1.1
        ) {
            self.id = UUID()
            self.name = name
            self.temperature = temperature
            self.topP = topP
            self.repeatPenalty = repeatPenalty
            self.createdAt = Date()
        }
    }

    /// Frozen V1 snapshot of `APIEndpoint`.
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

        public var provider: APIProvider {
            get { APIProvider(rawValue: providerRawValue) ?? .custom }
            set { providerRawValue = newValue.rawValue }
        }

        public var keychainAccount: String { id.uuidString }

        public var apiKey: String? {
            KeychainService.retrieve(account: keychainAccount)
        }

        @discardableResult
        public func setAPIKey(_ key: String) -> Bool {
            KeychainService.store(key: key, account: keychainAccount)
        }

        public func deleteAPIKey() {
            KeychainService.delete(account: keychainAccount)
        }

        public var isValid: Bool {
            guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else {
                return false
            }
            if !isLocalhost(url) && url.scheme != "https" {
                return false
            }
            if provider.requiresAPIKey && (apiKey?.isEmpty ?? true) {
                return false
            }
            return true
        }

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

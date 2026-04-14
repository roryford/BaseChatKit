import Foundation
import BaseChatInference
@preconcurrency import SwiftData

/// The current BaseChatKit SwiftData schema.
///
/// All model definitions live here. Previous schema versions (V1, V2) were
/// removed while the repo was still private — no users carry legacy data that
/// needs migration.
public enum BaseChatSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ChatMessage.self,
            ChatSession.self,
            SamplerPreset.self,
            APIEndpoint.self,
            ModelBenchmarkCache.self,
        ]
    }

    // MARK: - ChatMessage

    /// A single message in a chat conversation, persisted via SwiftData.
    ///
    /// Content is stored as a JSON-encoded `[MessagePart]` array in
    /// `contentPartsJSON`. The `content` property concatenates text parts
    /// for backward compatibility.
    @Model
    public final class ChatMessage {
        public var id: UUID
        public var role: MessageRole
        public var timestamp: Date
        public var sessionID: UUID

        /// Plain-text cache of the message content.
        public var content: String

        /// JSON-encoded `[MessagePart]` array. This is the source of truth for
        /// structured content.
        public var contentPartsJSON: String

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
            self.timestamp = Date()
            self.sessionID = sessionID
            self.content = content
            self.contentPartsJSON = Self.encode([.text(content)])
        }

        /// Creates a message from structured content parts.
        public init(
            role: MessageRole,
            contentParts: [MessagePart],
            sessionID: UUID
        ) {
            self.id = UUID()
            self.role = role
            self.timestamp = Date()
            self.sessionID = sessionID
            self.contentPartsJSON = Self.encode(contentParts)
            self.content = contentParts.compactMap(\.textContent).joined()
        }

        // MARK: - Content Parts

        /// The structured content parts of this message.
        public var contentParts: [MessagePart] {
            get { Self.decode(contentPartsJSON) }
            set {
                contentPartsJSON = Self.encode(newValue)
                content = newValue.compactMap(\.textContent).joined()
            }
        }

        // MARK: - JSON Helpers

        static func encode(_ parts: [MessagePart]) -> String {
            do {
                let data = try JSONEncoder().encode(parts)
                if let json = String(data: data, encoding: .utf8) {
                    return json
                }
                Log.persistence.warning("Failed to convert encoded MessagePart data to UTF-8 string")
            } catch {
                Log.persistence.error("Failed to encode MessagePart array: \(error)")
            }
            return "[]"
        }

        static func decode(_ json: String) -> [MessagePart] {
            guard let data = json.data(using: .utf8) else {
                Log.persistence.warning("contentPartsJSON is not valid UTF-8")
                return json.isEmpty ? [] : [.text(json)]
            }
            do {
                return try JSONDecoder().decode([MessagePart].self, from: data)
            } catch {
                Log.persistence.warning("Failed to decode contentPartsJSON, falling back to text: \(error)")
                return json.isEmpty ? [] : [.text(json)]
            }
        }
    }

    // MARK: - ChatSession

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
        /// Pinned messages are preserved when history is trimmed to fit the context window, regardless of age.
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

    // MARK: - SamplerPreset

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

    // MARK: - APIEndpoint

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

        /// Stores an API key in the Keychain for this endpoint.
        ///
        /// Throws `KeychainError.storeFailed` when the write is rejected
        /// (locked device, entitlement mismatch, corrupted item). Surface the
        /// error to the user — silently swallowing it leaves the impression
        /// that the key was saved when it wasn't.
        public func setAPIKey(_ key: String) throws {
            try KeychainService.store(key: key, account: keychainAccount)
        }

        /// Deletes the API key from the Keychain.
        ///
        /// Throws `KeychainError.deleteFailed` on Keychain errors. A missing
        /// item is not an error — callers can rely on this being idempotent.
        public func deleteAPIKey() throws {
            try KeychainService.delete(account: keychainAccount)
        }

        /// Validates the endpoint's URL structure.
        ///
        /// This is a pure structural check — it does NOT verify whether an API key
        /// exists in the Keychain. Use `APIProvider.requiresAPIKey` and
        /// `KeychainService.retrieve(account: endpoint.keychainAccount)` separately
        /// to check credential readiness.
        ///
        /// Security: rejects URLs that would let a malicious endpoint config pivot
        /// into the user's LAN or cloud metadata services (SSRF). See
        /// ``APIEndpoint/isDisallowedPrivateHost(_:)`` for the blocked IP ranges.
        /// Only `http`/`https` schemes are accepted. Non-HTTPS is permitted only for
        /// the explicit loopback allowlist (`127.0.0.1`, `::1`, `localhost`).
        public var isValid: Bool {
            guard let url = URL(string: baseURL),
                  let scheme = url.scheme?.lowercased(),
                  url.host() != nil else {
                return false
            }

            // Only http/https are valid. Reject file, ftp, data, javascript, etc.
            guard scheme == "http" || scheme == "https" else {
                return false
            }

            // Loopback dev servers (e.g. Ollama, LM Studio) are allowed over plain HTTP.
            if Self.isLocalhost(url) {
                return true
            }

            // Non-loopback must be HTTPS.
            if scheme != "https" {
                return false
            }

            // Block SSRF into LAN / cloud metadata even when HTTPS is used. A
            // cert-pinned private-range target is still a private-range target.
            if Self.isDisallowedPrivateHost(url) {
                return false
            }

            return true
        }

        /// Checks if the URL points to a local server.
        ///
        /// Only the explicit loopback literals are matched — broader `127.x.x.x`
        /// and IPv4-mapped IPv6 loopback (`::ffff:127.0.0.1`) are intentionally
        /// excluded because they are easy SSRF bypass vectors.
        static func isLocalhost(_ url: URL) -> Bool {
            guard let host = url.host()?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }

        /// Classifies a URL's host as pointing at a private, link-local, or
        /// otherwise reserved IP range.
        ///
        /// Only IP literals are inspected. DNS names are not resolved — validation
        /// is called synchronously from SwiftUI settings forms and must stay fast.
        /// DNS rebinding is therefore out of scope for this layer and should be
        /// mitigated at the request layer (e.g. by pinning resolution or by
        /// rejecting private IPs returned by `URLSession` host resolution) if a
        /// deployment needs that guarantee.
        ///
        /// Blocked IPv4 ranges:
        /// - `0.0.0.0/8` (non-routable "this host")
        /// - `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (RFC1918)
        /// - `127.0.0.0/8` except `127.0.0.1` (alternate loopback encodings)
        /// - `169.254.0.0/16` (link-local incl. AWS/GCP/Azure metadata at `169.254.169.254`)
        /// - `224.0.0.0/4` (multicast) and `240.0.0.0/4` (reserved/future use)
        ///
        /// Blocked IPv6 ranges:
        /// - `fc00::/7` (unique local addresses)
        /// - `fe80::/10` (link-local)
        /// - `::ffff:0:0/96` (IPv4-mapped; would otherwise bypass the IPv4 filter)
        static func isDisallowedPrivateHost(_ url: URL) -> Bool {
            guard let rawHost = url.host()?.lowercased() else { return false }

            // FQDN form with a trailing dot (e.g. `192.168.1.1.`) resolves
            // identically to the dotless form on every mainstream resolver, so
            // treat it as equivalent for IP-literal classification. Without
            // this, `https://192.168.1.1.` would bypass the private-range
            // gate and reach a LAN host under HTTPS.
            let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

            if let octets = parseIPv4Literal(host) {
                return isDisallowedIPv4(octets)
            }

            if let words = parseIPv6Literal(host) {
                return isDisallowedIPv6(words)
            }

            // DNS names reach here. Do not resolve synchronously — return false
            // and rely on the HTTPS-required rule plus any higher-layer mitigation.
            return false
        }

        // MARK: IPv4

        /// Parses a dotted-quad IPv4 literal into four octets.
        ///
        /// Returns `nil` for anything that isn't exactly four 0-255 components
        /// (including shorthand forms like `127.1`, which `inet_aton` would accept
        /// but modern URL parsers reject).
        private static func parseIPv4Literal(_ host: String) -> [UInt8]? {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var octets: [UInt8] = []
            octets.reserveCapacity(4)
            for part in parts {
                guard !part.isEmpty, part.allSatisfy(\.isASCII),
                      let value = UInt16(part), value <= 255 else {
                    return nil
                }
                octets.append(UInt8(value))
            }
            return octets
        }

        private static func isDisallowedIPv4(_ octets: [UInt8]) -> Bool {
            let a = octets[0]
            let b = octets[1]

            // 0.0.0.0/8 — "this host" / any-address
            if a == 0 { return true }
            // 10.0.0.0/8 — RFC1918
            if a == 10 { return true }
            // 127.0.0.0/8 — loopback; the exact 127.0.0.1 is approved by
            // isLocalhost before this helper is called, so any 127.x.x.x
            // reaching here is an alternate loopback encoding.
            if a == 127 { return true }
            // 169.254.0.0/16 — link-local (AWS/GCP/Azure IMDS sits here)
            if a == 169 && b == 254 { return true }
            // 172.16.0.0/12 — RFC1918
            if a == 172 && (16...31).contains(b) { return true }
            // 192.168.0.0/16 — RFC1918
            if a == 192 && b == 168 { return true }
            // 224.0.0.0/4 — multicast
            if (224...239).contains(a) { return true }
            // 240.0.0.0/4 — reserved / future use (includes 255.255.255.255 broadcast)
            if a >= 240 { return true }

            return false
        }

        // MARK: IPv6

        /// Parses an IPv6 literal (as returned by `URL.host()` — without the
        /// surrounding brackets) into eight 16-bit words.
        ///
        /// Supports `::` zero-run compression and embedded IPv4 suffixes
        /// (e.g. `::ffff:127.0.0.1`). Zone identifiers (`fe80::1%en0`) are
        /// stripped before parsing.
        private static func parseIPv6Literal(_ host: String) -> [UInt16]? {
            // Strip IPv6 zone identifier if present.
            let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
            guard bare.contains(":") else { return nil }

            // Split on "::" which represents a run of zero words.
            let doubleColonParts = bare.components(separatedBy: "::")
            guard doubleColonParts.count <= 2 else { return nil }

            func expand(_ segment: String) -> [UInt16]? {
                if segment.isEmpty { return [] }
                let groups = segment.split(separator: ":", omittingEmptySubsequences: false)
                var words: [UInt16] = []
                for (i, group) in groups.enumerated() {
                    if group.contains(".") {
                        // Embedded IPv4 — only legal as the last group.
                        guard i == groups.count - 1,
                              let v4 = parseIPv4Literal(String(group)) else { return nil }
                        let high = (UInt16(v4[0]) << 8) | UInt16(v4[1])
                        let low = (UInt16(v4[2]) << 8) | UInt16(v4[3])
                        words.append(high)
                        words.append(low)
                    } else {
                        guard !group.isEmpty, group.count <= 4,
                              let value = UInt16(group, radix: 16) else { return nil }
                        words.append(value)
                    }
                }
                return words
            }

            let head = expand(doubleColonParts[0])
            let tail = doubleColonParts.count == 2 ? expand(doubleColonParts[1]) : []
            guard let headWords = head, let tailWords = tail else { return nil }

            let total = headWords.count + tailWords.count
            if doubleColonParts.count == 2 {
                guard total <= 8 else { return nil }
                let zeros = Array(repeating: UInt16(0), count: 8 - total)
                return headWords + zeros + tailWords
            } else {
                guard total == 8 else { return nil }
                return headWords
            }
        }

        private static func isDisallowedIPv6(_ words: [UInt16]) -> Bool {
            guard words.count == 8 else { return false }

            // fc00::/7 — unique local addresses (first 7 bits are 1111110).
            if (words[0] & 0xfe00) == 0xfc00 { return true }
            // fe80::/10 — link-local (first 10 bits are 1111111010).
            if (words[0] & 0xffc0) == 0xfe80 { return true }
            // ::ffff:0:0/96 — IPv4-mapped IPv6. Reject so mapped loopback /
            // mapped RFC1918 can't bypass the IPv4 filter.
            let isIPv4Mapped = words[0] == 0 && words[1] == 0 && words[2] == 0
                && words[3] == 0 && words[4] == 0 && words[5] == 0xffff
            if isIPv4Mapped { return true }

            return false
        }
    }

    // MARK: - ModelBenchmarkCache

    /// Persists a ``ModelBenchmarkResult`` keyed by the model's file name.
    ///
    /// SwiftData does not natively support storing enums or nested Codable structs
    /// as columns, so the result is decomposed into scalar fields. Use ``toResult()``
    /// to reconstitute a ``ModelBenchmarkResult`` value.
    @Model
    public final class ModelBenchmarkCache {

        /// The file name of the model this result belongs to (e.g. `"model.Q4_K_M.gguf"`).
        public var modelFileName: String

        /// Raw ``ModelCapabilityTier/rawValue`` for the stored tier.
        public var tierRaw: Int

        /// Measured tokens-per-second, or `nil` if not available.
        public var tokensPerSecond: Double?

        /// Peak memory usage in bytes, or `nil` if not available.
        public var memoryBytes: Int64?

        /// When the benchmark was performed.
        public var measuredAt: Date

        /// The capability tier stored in this cache entry.
        public var tier: ModelCapabilityTier {
            ModelCapabilityTier(rawValue: tierRaw) ?? .minimal
        }

        public init(modelFileName: String, result: ModelBenchmarkResult) {
            self.modelFileName = modelFileName
            self.tierRaw = result.tier.rawValue
            self.tokensPerSecond = result.tokensPerSecond
            self.memoryBytes = result.memoryBytes
            self.measuredAt = result.measuredAt
        }

        /// Reconstitutes a ``ModelBenchmarkResult`` from this cache entry.
        public func toResult() -> ModelBenchmarkResult {
            ModelBenchmarkResult(
                tier: tier,
                tokensPerSecond: tokensPerSecond,
                memoryBytes: memoryBytes,
                measuredAt: measuredAt
            )
        }
    }
}

/// Public typealias so host code uses `ModelBenchmarkCache` without schema qualification.
public typealias ModelBenchmarkCache = BaseChatSchemaV3.ModelBenchmarkCache

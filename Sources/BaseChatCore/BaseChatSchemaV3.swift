import Foundation
import SwiftData

/// Version 3 of the BaseChatKit SwiftData schema.
///
/// Adds ``ModelBenchmarkCache`` for persisting benchmark results keyed by model
/// file name. No existing model types are modified — this is a lightweight
/// additive migration.
///
/// ## Migration from V2
///
/// A lightweight migration stage adds the new `ModelBenchmarkCache` entity.
/// No data transformation is required.
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

    // Existing types are unchanged from V2/V1 — redeclare as typealiases so the
    // schema enumerates all model types.
    typealias ChatMessage = BaseChatSchemaV2.ChatMessage
    typealias ChatSession = BaseChatSchemaV1.ChatSession
    typealias SamplerPreset = BaseChatSchemaV1.SamplerPreset
    typealias APIEndpoint = BaseChatSchemaV1.APIEndpoint

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

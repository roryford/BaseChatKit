import Foundation
import BaseChatInference

public struct RunRecord: Codable, Sendable, Equatable {
    /// Current `RunRecord` on-disk schema. Bump when the shape changes.
    /// See `BaseChatFuzz.docc/RunRecordSchema.md` for the evolution procedure.
    public static let currentSchema: Int = 1

    /// Version of the on-disk shape this record was written with. Legacy records
    /// without the field decode as `1` via `init(from:)` below.
    public var schemaVersion: Int = Self.currentSchema
    public var runId: String
    public var ts: String
    public var harness: HarnessSnapshot
    public var model: ModelSnapshot
    public var config: ConfigSnapshot
    public var prompt: PromptSnapshot
    public var events: [EventSnapshot]
    public var raw: String
    /// Historical duplicate of `raw` — retained for one release cycle so external
    /// record consumers can migrate off it without a hard break. `FuzzRunner` and
    /// `Replayer` still populate it from `capture.raw`; detectors now read `raw`
    /// directly. Tracked for removal once the "real UI-transform rendering" path
    /// is wired up (see follow-up issue).
    ///
    /// - Deprecated: use `raw` instead; `rendered` will be removed in a later release.
    public var rendered: String
    public var thinkingRaw: String
    public var thinkingParts: [String]
    public var thinkingCompleteCount: Int
    public var templateMarkers: MarkerSnapshot?
    public var memory: MemorySnapshot
    public var timing: TimingSnapshot
    public var phase: String
    public var error: String?
    /// Coarse stop classification: `naturalStop`, `maxTokens`, `userStop`, `error`, `unknown`.
    /// Detectors gate on this to avoid false positives from token-cap truncation.
    public var stopReason: String?

    public init(
        schemaVersion: Int = RunRecord.currentSchema,
        runId: String,
        ts: String,
        harness: HarnessSnapshot,
        model: ModelSnapshot,
        config: ConfigSnapshot,
        prompt: PromptSnapshot,
        events: [EventSnapshot],
        raw: String,
        rendered: String,
        thinkingRaw: String,
        thinkingParts: [String],
        thinkingCompleteCount: Int,
        templateMarkers: MarkerSnapshot? = nil,
        memory: MemorySnapshot,
        timing: TimingSnapshot,
        phase: String,
        error: String? = nil,
        stopReason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runId = runId
        self.ts = ts
        self.harness = harness
        self.model = model
        self.config = config
        self.prompt = prompt
        self.events = events
        self.raw = raw
        self.rendered = rendered
        self.thinkingRaw = thinkingRaw
        self.thinkingParts = thinkingParts
        self.thinkingCompleteCount = thinkingCompleteCount
        self.templateMarkers = templateMarkers
        self.memory = memory
        self.timing = timing
        self.phase = phase
        self.error = error
        self.stopReason = stopReason
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runId, ts, harness, model, config, prompt, events, raw, rendered
        case thinkingRaw, thinkingParts, thinkingCompleteCount, templateMarkers
        case memory, timing, phase, error, stopReason
    }

    /// Decodes a record, defaulting `schemaVersion` to `1` when the field is
    /// absent so legacy on-disk records round-trip cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.runId = try c.decode(String.self, forKey: .runId)
        self.ts = try c.decode(String.self, forKey: .ts)
        self.harness = try c.decode(HarnessSnapshot.self, forKey: .harness)
        self.model = try c.decode(ModelSnapshot.self, forKey: .model)
        self.config = try c.decode(ConfigSnapshot.self, forKey: .config)
        self.prompt = try c.decode(PromptSnapshot.self, forKey: .prompt)
        self.events = try c.decode([EventSnapshot].self, forKey: .events)
        self.raw = try c.decode(String.self, forKey: .raw)
        self.rendered = try c.decode(String.self, forKey: .rendered)
        self.thinkingRaw = try c.decode(String.self, forKey: .thinkingRaw)
        self.thinkingParts = try c.decode([String].self, forKey: .thinkingParts)
        self.thinkingCompleteCount = try c.decode(Int.self, forKey: .thinkingCompleteCount)
        self.templateMarkers = try c.decodeIfPresent(MarkerSnapshot.self, forKey: .templateMarkers)
        self.memory = try c.decode(MemorySnapshot.self, forKey: .memory)
        self.timing = try c.decode(TimingSnapshot.self, forKey: .timing)
        self.phase = try c.decode(String.self, forKey: .phase)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
    }

    /// Errors surfaced by `validate(schemaVersion:)`.
    public enum SchemaError: Error, Equatable, Sendable {
        /// Raised when a record's `schemaVersion` exceeds `currentSchema` — the
        /// loader is from an older build than the writer and cannot be trusted
        /// to interpret the payload.
        case unsupportedFutureSchema(Int)
    }

    /// Validates a decoded record's `schemaVersion`. Future versions throw;
    /// older-than-current versions log a warning so callers know a migration
    /// is being applied. The `--replay` loader (#490) will call this before
    /// acting on a record.
    public static func validate(schemaVersion v: Int) throws {
        if v > currentSchema {
            throw SchemaError.unsupportedFutureSchema(v)
        }
        if v < currentSchema {
            Log.inference.warning(
                "RunRecord: decoding legacy schemaVersion \(v, privacy: .public) (current is \(currentSchema, privacy: .public)); migration shim applied."
            )
        }
    }

    public struct HarnessSnapshot: Codable, Sendable, Equatable {
        public var fuzzVersion: String
        public var packageGitRev: String
        public var packageGitDirty: Bool
        public var swiftVersion: String
        public var osBuild: String
        public var thermalState: String
    }

    public struct ModelSnapshot: Codable, Sendable, Equatable {
        public var backend: String
        public var id: String
        public var url: String
        public var fileSHA256: String?
        public var tokenizerHash: String?
    }

    public struct ConfigSnapshot: Codable, Sendable, Equatable {
        public var seed: UInt64
        public var temperature: Float
        public var topP: Float
        public var maxTokens: Int?
        public var systemPrompt: String?
    }

    public struct PromptSnapshot: Codable, Sendable, Equatable {
        public var corpusId: String
        public var mutators: [String]
        public var messages: [Message]

        public struct Message: Codable, Sendable, Equatable {
            public var role: String
            public var text: String
        }
    }

    public struct EventSnapshot: Codable, Sendable, Equatable {
        public var t: Double
        public var kind: String
        public var v: String?
    }

    public struct MarkerSnapshot: Codable, Sendable, Equatable {
        public var open: String
        public var close: String
        public init(open: String, close: String) {
            self.open = open
            self.close = close
        }
    }

    public struct MemorySnapshot: Codable, Sendable, Equatable {
        public var beforeBytes: UInt64?
        public var peakBytes: UInt64?
        public var afterBytes: UInt64?
    }

    public struct TimingSnapshot: Codable, Sendable, Equatable {
        public var firstTokenMs: Double?
        public var totalMs: Double
        public var tokensPerSec: Double?
    }
}

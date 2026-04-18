import Foundation

public struct RunRecord: Codable, Sendable {
    public var runId: String
    public var ts: String
    public var harness: HarnessSnapshot
    public var model: ModelSnapshot
    public var config: ConfigSnapshot
    public var prompt: PromptSnapshot
    public var events: [EventSnapshot]
    public var raw: String
    public var rendered: String
    public var thinkingRaw: String
    public var thinkingParts: [String]
    public var thinkingCompleteCount: Int
    public var templateMarkers: MarkerSnapshot?
    public var memory: MemorySnapshot
    public var timing: TimingSnapshot
    public var phase: String
    public var error: String?

    public struct HarnessSnapshot: Codable, Sendable {
        public var fuzzVersion: String
        public var packageGitRev: String
        public var packageGitDirty: Bool
        public var swiftVersion: String
        public var osBuild: String
        public var thermalState: String
    }

    public struct ModelSnapshot: Codable, Sendable {
        public var backend: String
        public var id: String
        public var url: String
        public var fileSHA256: String?
        public var tokenizerHash: String?
    }

    public struct ConfigSnapshot: Codable, Sendable {
        public var seed: UInt64
        public var temperature: Float
        public var topP: Float
        public var maxTokens: Int?
        public var systemPrompt: String?
    }

    public struct PromptSnapshot: Codable, Sendable {
        public var corpusId: String
        public var mutators: [String]
        public var messages: [Message]

        public struct Message: Codable, Sendable {
            public var role: String
            public var text: String
        }
    }

    public struct EventSnapshot: Codable, Sendable {
        public var t: Double
        public var kind: String
        public var v: String?
    }

    public struct MarkerSnapshot: Codable, Sendable {
        public var open: String
        public var close: String
        public init(open: String, close: String) {
            self.open = open
            self.close = close
        }
    }

    public struct MemorySnapshot: Codable, Sendable {
        public var beforeBytes: UInt64?
        public var peakBytes: UInt64?
        public var afterBytes: UInt64?
    }

    public struct TimingSnapshot: Codable, Sendable {
        public var firstTokenMs: Double?
        public var totalMs: Double
        public var tokensPerSec: Double?
    }
}

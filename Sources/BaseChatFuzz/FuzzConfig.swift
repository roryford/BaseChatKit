import Foundation

public enum BackendChoice: String, Sendable, CaseIterable {
    case ollama
    case llama
    case foundation
    case mlx
    case all
}

public struct FuzzConfig: Sendable {
    public let backend: BackendChoice
    public let minutes: Int?
    public let iterations: Int?
    public let seed: UInt64
    public let modelHint: String?
    public let detectorFilter: Set<String>?
    public let outputDir: URL
    public let calibrate: Bool
    public let quiet: Bool
    /// When `true`, the harness drives multi-turn scripts through
    /// ``SessionFuzzRunner`` instead of the single-turn ``FuzzRunner``.
    /// Additive today — the single-turn path is unchanged.
    public let sessionScripts: Bool

    public init(
        backend: BackendChoice = .ollama,
        minutes: Int? = nil,
        iterations: Int? = nil,
        seed: UInt64 = UInt64.random(in: 0...UInt64.max),
        modelHint: String? = nil,
        detectorFilter: Set<String>? = nil,
        outputDir: URL = URL(fileURLWithPath: "tmp/fuzz", isDirectory: true),
        calibrate: Bool = false,
        quiet: Bool = false,
        sessionScripts: Bool = false
    ) {
        self.backend = backend
        self.minutes = minutes
        self.iterations = iterations
        self.seed = seed
        self.modelHint = modelHint
        self.detectorFilter = detectorFilter
        self.outputDir = outputDir
        self.calibrate = calibrate
        self.quiet = quiet
        self.sessionScripts = sessionScripts
    }
}

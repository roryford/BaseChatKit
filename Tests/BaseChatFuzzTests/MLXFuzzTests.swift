#if MLX
import XCTest
@testable import BaseChatFuzz
import BaseChatBackends
import BaseChatInference
import BaseChatTestSupport

/// XCTest fuzz driver for `MLXBackend`. Runs via the xcodebuild path because
/// MLX's Metal shaders are only compiled under Xcode — not by SwiftPM.
///
/// Run with:
/// ```
/// xcodebuild test -scheme BaseChatKit-Package \
///     -only-testing BaseChatFuzzTests/MLXFuzzTests \
///     -destination 'platform=macOS'
/// ```
/// or via the wrapper:
/// ```
/// scripts/fuzz.sh --with-mlx --minutes 1
/// ```
final class MLXFuzzTests: XCTestCase {

    private var modelURL: URL!
    private var outputDir: URL!

    /// Walks up from this source file to the directory containing `Package.swift`.
    /// Reliable under both `swift run` (cwd = repo root) and `xcodebuild` (cwd = DerivedData).
    private static func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #file)
        while dir.path != "/" {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "MLXBackend requires Apple Silicon (arm64)")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice,
                          "MLXBackend requires a Metal GPU device (unavailable in simulator)")
        guard let found = HardwareRequirements.findMLXModelDirectory() else {
            throw XCTSkip(
                "No MLX model found in ~/Documents/Models/. "
                    + "Download a safetensors model to run MLX fuzz tests."
            )
        }
        modelURL = found
        outputDir = Self.repoRoot().appendingPathComponent("tmp/fuzz", isDirectory: true)
        // Let the error propagate so setUp() fails loudly if the output directory
        // cannot be created (e.g. permissions, read-only checkout), rather than
        // masking the problem and producing a harder-to-diagnose test failure later.
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
    }

    /// Drives `MLXBackend` for 5 iterations using all registered detectors.
    /// Findings (if any) land in `tmp/fuzz/INDEX.md` alongside Ollama results.
    func test_mlxFuzz_runsAtLeastFiveIterations() async throws {
        let config = FuzzConfig(
            backend: .mlx,
            iterations: 5,
            seed: 42,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke
        )
        let factory = MLXFuzzFactory(modelURL: modelURL)
        let runner = FuzzRunner(config: config, factory: factory)
        let reporter = TerminalReporter(quiet: true)
        let report = await runner.run(reporter: reporter)
        XCTAssertGreaterThanOrEqual(
            report.totalRuns, 5,
            "MLX fuzz campaign must complete at least 5 iterations"
        )
    }
}

/// `FuzzBackendFactory` that instantiates `MLXBackend` from a local safetensors
/// directory. Defined here (rather than `Sources/fuzz-chat/`) because `fuzz-chat`
/// is an executable target and cannot be imported by test targets.
private struct MLXFuzzFactory: FuzzBackendFactory {
    let modelURL: URL

    @MainActor
    func makeHandle() async throws -> FuzzRunner.BackendHandle {
        let backend = MLXBackend()
        try await backend.loadModel(
            from: modelURL,
            plan: .testStub(effectiveContextSize: 4096)
        )
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: modelURL.lastPathComponent,
            modelURL: modelURL,
            backendName: "mlx",
            templateMarkers: nil
        )
    }
}
#endif

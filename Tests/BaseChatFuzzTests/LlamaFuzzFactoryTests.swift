#if Llama
import XCTest
@testable import BaseChatFuzz
import BaseChatBackends
import BaseChatInference
import BaseChatTestSupport

/// XCTest fuzz driver for `LlamaBackend`. Verifies that the
/// `LlamaFuzzFactory` shipped in `Sources/fuzz-chat/` can produce a loaded
/// `LlamaBackend` handle and run at least one iteration through the
/// `FuzzRunner` — the acceptance criterion for issue #560.
///
/// Mirrors the local-factory pattern from `MockFuzzFactoryTests` /
/// `ChaosFuzzFactoryTests`: SPM test targets cannot import an
/// `executableTarget`, so the factory under test is re-declared here. Any
/// behavioural divergence between this copy and the executable's copy should
/// either be cleaned up in both places or reflected with a distinct test —
/// keep them structurally identical.
///
/// Skipped when the host lacks Apple Silicon, lacks Metal, or has no GGUF model
/// installed in `~/Documents/Models/`. Llama requires real Metal and a real
/// model to load — there is no mock path that exercises `LlamaFuzzFactory`'s
/// real responsibility (model discovery + backend bring-up).
final class LlamaFuzzFactoryTests: XCTestCase {

    /// Test-local mirror of `Sources/fuzz-chat/LlamaFuzzFactory.swift`.
    /// Implemented as a `final class` to match the executable copy's lifetime
    /// model, where `teardown()` awaits the same `LlamaBackend` instance that
    /// `makeHandle()` loaded.
    final class LocalLlamaFuzzFactory: FuzzBackendFactory, @unchecked Sendable {
        private var backend: LlamaBackend?

        init() {}

        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            guard let modelURL = HardwareRequirements.findGGUFModel() else {
                throw NSError(
                    domain: "LlamaFuzzFactoryTests",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No GGUF model found"]
                )
            }
            let b = LlamaBackend()
            try await b.loadModel(
                from: modelURL,
                plan: .testStub(effectiveContextSize: 4096)
            )
            backend = b
            return FuzzRunner.BackendHandle(
                backend: b,
                modelId: modelURL.lastPathComponent,
                modelURL: modelURL,
                backendName: "llama",
                templateMarkers: nil
            )
        }

        func teardown() async {
            await backend?.unloadAndWait()
        }
    }

    private var modelURL: URL!
    private var outputDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon (arm64)")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice,
                          "LlamaBackend requires a Metal GPU device (unavailable in simulator)")
        guard let found = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found in ~/Documents/Models/. "
                    + "Download a GGUF model (e.g. via the demo app) to run Llama fuzz tests."
            )
        }
        modelURL = found
        outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-fuzz-factory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let outputDir { try? FileManager.default.removeItem(at: outputDir) }
        try super.tearDownWithError()
    }

    /// `makeHandle()` returns a handle whose backend is loaded and ready to
    /// generate. Same invariant the runner depends on: the first `generate`
    /// call must not throw because the model isn't loaded.
    func test_makeHandle_returnsLoadedBackend() async throws {
        let factory = LocalLlamaFuzzFactory()
        let handle = try await factory.makeHandle()
        defer { Task { await factory.teardown() } }

        XCTAssertTrue(handle.backend.isModelLoaded,
                      "factory must pre-load the backend so the runner's first generate() succeeds")
        XCTAssertEqual(handle.backendName, "llama")
        XCTAssertEqual(handle.modelId, modelURL.lastPathComponent)
        XCTAssertEqual(handle.modelURL, modelURL)
    }

    /// End-to-end: factory handle feeds `FuzzRunner.run` for one iteration and
    /// produces a non-zero total-run count. Acceptance criterion for #560:
    /// `swift run fuzz-chat --backend llama --iterations 1` must run >= 1
    /// iteration against an installed GGUF.
    func test_factoryDrivesOneIterationThroughRunner() async {
        let config = FuzzConfig(
            backend: .llama,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke
        )
        let factory = LocalLlamaFuzzFactory()
        let runner = FuzzRunner(config: config, factory: factory)
        let report = await runner.run(reporter: TerminalReporter(quiet: true))
        await factory.teardown()

        XCTAssertGreaterThanOrEqual(
            report.totalRuns, 1,
            "Llama fuzz campaign must complete at least 1 iteration against the installed GGUF"
        )
    }

    /// Documents the single-model constraint in #560: `llama_backend_init` is
    /// a process-global one-shot, so the factory advertises deterministic
    /// replay (seed + temperature=0 → bit-identical) and `Replayer` will not
    /// short-circuit with `.nonDeterministicBackend`.
    func test_supportsDeterministicReplay_isTrue() {
        let factory = LocalLlamaFuzzFactory()
        XCTAssertTrue(
            factory.supportsDeterministicReplay,
            "Llama is deterministic with seed + temperature=0; promotion threshold defaults are safe"
        )
    }
}
#endif // Llama

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
/// `ChaosFuzzFactoryTests` and the contract-pinning shape of
/// `FoundationFuzzFactoryTests` (PR #825): SPM test targets cannot import an
/// `executableTarget`, so the factory under test is re-declared here. Any
/// behavioural divergence between this copy and the executable's copy should
/// either be cleaned up in both places or reflected with a distinct test —
/// keep them structurally identical.
///
/// Pure-value contract tests run on every host. The handle-loading and
/// end-to-end runner tests are hardware-gated: they skip when the host lacks
/// Apple Silicon, lacks Metal, or has no GGUF model installed in
/// `~/Documents/Models/`. Llama requires real Metal and a real model to load —
/// there is no mock path that exercises `LlamaFuzzFactory`'s real
/// responsibility (model discovery + backend bring-up).
final class LlamaFuzzFactoryTests: XCTestCase {

    /// Test-local mirror of `Sources/fuzz-chat/LlamaFuzzFactory.swift`.
    /// Implemented as a `final class` to match the executable copy's lifetime
    /// model, where `teardown()` awaits the same `LlamaBackend` instance that
    /// `makeHandle()` loaded.
    final class LocalLlamaFuzzFactory: FuzzBackendFactory, @unchecked Sendable {
        private var backend: LlamaBackend?

        init() {}

        /// Stated explicitly to mirror the executable copy and keep readers'
        /// intent obvious side-by-side with `FoundationFuzzFactory`.
        var supportsDeterministicReplay: Bool { true }

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

    // MARK: - Pure-value contract (runs on every host)

    /// Documents the single-model constraint in #560: `llama_backend_init` is
    /// a process-global one-shot, so the factory advertises deterministic
    /// replay (seed + temperature=0 → bit-identical) and `Replayer` will not
    /// short-circuit with `.nonDeterministicBackend`. Pure-value — no hardware
    /// or model needed, so this runs on every host the test target builds on.
    func test_supportsDeterministicReplay_isTrue() {
        let factory = LocalLlamaFuzzFactory()
        XCTAssertTrue(
            factory.supportsDeterministicReplay,
            "Llama is deterministic with seed + temperature=0; promotion threshold defaults are safe"
        )
    }

    // MARK: - Hardware-gated handle + runner

    private func skipUnlessHardwareReady() throws -> URL {
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
        return found
    }

    private func makeTempOutputDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-fuzz-factory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `makeHandle()` returns a handle whose backend is loaded and ready to
    /// generate. Same invariant the runner depends on: the first `generate`
    /// call must not throw because the model isn't loaded.
    func test_makeHandle_returnsLoadedBackend() async throws {
        let modelURL = try skipUnlessHardwareReady()
        let factory = LocalLlamaFuzzFactory()
        let handle = try await factory.makeHandle()
        defer { Task { await factory.teardown() } }

        XCTAssertTrue(handle.backend.isModelLoaded,
                      "factory must pre-load the backend so the runner's first generate() succeeds")
        XCTAssertEqual(handle.backendName, "llama")
        XCTAssertEqual(handle.modelId, modelURL.lastPathComponent)
        XCTAssertEqual(handle.modelURL, modelURL)
        XCTAssertNil(
            handle.templateMarkers,
            "Llama relies on InferenceService for prompt formatting — the factory leaves template markers unset"
        )
    }

    /// End-to-end: factory handle feeds `FuzzRunner.run` for one iteration and
    /// produces a non-zero total-run count. Acceptance criterion for #560:
    /// `swift run fuzz-chat --backend llama --iterations 1` must run >= 1
    /// iteration against an installed GGUF.
    func test_factoryDrivesOneIterationThroughRunner() async throws {
        _ = try skipUnlessHardwareReady()
        let outputDir = try makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

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
}
#endif // Llama

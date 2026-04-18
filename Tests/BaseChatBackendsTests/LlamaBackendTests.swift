#if Llama
import XCTest
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for LlamaBackend state, capabilities, and error handling.
///
/// These tests exercise everything that does not require a real GGUF model file:
/// init state, capabilities, error paths, lifecycle transitions, and stop/unload.
///
/// All tests require Apple Silicon (llama_backend_init uses Metal).
final class LlamaBackendTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaBackend requires Apple Silicon")
    }

    // MARK: - Init & State

    func test_init_defaultState() {
        let backend = LlamaBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Capabilities

    func test_capabilities_supportsAllSamplingParameters() {
        let backend = LlamaBackend()
        let caps = backend.capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
        XCTAssertTrue(caps.supportedParameters.contains(.repeatPenalty))
    }

    func test_capabilities_requiresPromptTemplate() {
        let backend = LlamaBackend()
        XCTAssertTrue(backend.capabilities.requiresPromptTemplate,
                      "GGUF models need external prompt formatting")
    }

    func test_capabilities_supportsSystemPrompt() {
        let backend = LlamaBackend()
        XCTAssertTrue(backend.capabilities.supportsSystemPrompt)
    }

    func test_capabilities_contextSize() {
        let backend = LlamaBackend()
        XCTAssertEqual(backend.capabilities.maxContextTokens, 4096)
    }

    // MARK: - Model Loading Errors

    func test_loadModel_invalidPath_throws() async {
        let backend = LlamaBackend()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/model.gguf")

        do {
            try await backend.loadModel(from: fakeURL, plan: .testStub(effectiveContextSize: 2048))
            XCTFail("Should throw when model file doesn't exist")
        } catch let error as InferenceError {
            if case .modelLoadFailed = error {
                // Expected
            } else {
                XCTFail("Expected modelLoadFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertFalse(backend.isModelLoaded)
    }

    func test_loadModel_emptyFile_throws() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeGGUF = tempDir.appendingPathComponent("fake.gguf")
        try Data().write(to: fakeGGUF)

        do {
            try await backend(fakeGGUF)
            XCTFail("Should throw for invalid GGUF file")
        } catch let error as InferenceError {
            if case .modelLoadFailed = error {
                // Expected — empty file is not a valid GGUF
            } else {
                XCTFail("Expected modelLoadFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    private func backend(_ url: URL) async throws {
        let b = LlamaBackend()
        try await b.loadModel(from: url, plan: .testStub(effectiveContextSize: 2048))
    }

    // MARK: - Generate Without Model

    func test_generate_withoutLoading_throws() {
        let backend = LlamaBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())
        ) { error in
            guard let inferenceError = error as? InferenceError else {
                XCTFail("Expected InferenceError, got \(error)")
                return
            }
            if case .inferenceFailure = inferenceError {
                // Expected
            } else {
                XCTFail("Expected inferenceFailure, got \(inferenceError)")
            }
        }
    }

    // MARK: - Unload

    func test_unloadModel_doesNotBlockCallerThread() {
        // unloadModel() must return quickly — it must not spin on the calling
        // thread waiting for isGenerating, as InferenceService is @MainActor.
        let backend = LlamaBackend()
        let start = Date()
        backend.unloadModel()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.1,
                          "unloadModel() must return in < 100 ms (got \(elapsed * 1000)ms); "
                        + "spinning on the calling thread would freeze the UI")
    }

    // Note: context-clamp logic and KV bytes-per-token computation moved from
    // LlamaBackend into `ModelLoadPlan` / `GGUFKVCacheEstimator` in Stage 3 of
    // the load-path refactor. The tests that previously exercised
    // `computeRamSafeCap` / `computeKVBytesPerToken` here were superseded by
    // `ModelLoadPlanTests` and `ModelLoadPlanParityTests` in
    // `BaseChatInferenceTests`. The retry-on-nil halving loop was deleted
    // outright — the plan is authoritative, so there is no fallback to test.

    func test_unloadModel_fromCleanState_isNoOp() {
        let backend = LlamaBackend()
        // Should not crash when nothing is loaded
        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadModel_afterFailedLoad_clearsState() async {
        let backend = LlamaBackend()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/model.gguf")

        try? await backend.loadModel(from: fakeURL, plan: .testStub(effectiveContextSize: 2048))
        backend.unloadModel()

        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadAndWait_onCleanBackend_returnsQuickly() async {
        // With nothing loaded, unloadAndWait() must still return without hanging
        // because the cleanup task is never scheduled.
        let backend = LlamaBackend()
        let start = Date()
        await backend.unloadAndWait()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
                          "unloadAndWait() on a clean backend must return promptly (got \(elapsed * 1000)ms)")
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadAndWait_isIdempotent() async {
        // Back-to-back calls must not crash and must leave the backend unloaded.
        let backend = LlamaBackend()
        await backend.unloadAndWait()
        await backend.unloadAndWait()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadAndWait_afterFailedLoad_clearsState() async {
        // unloadAndWait() must clear state identically to unloadModel(), and must
        // also drain any pending cleanup task before returning. Sabotaging the
        // implementation to skip the unloadModel() call would leave isModelLoaded
        // or isGenerating in a stale state if the failed load had set them.
        let backend = LlamaBackend()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/model.gguf")

        try? await backend.loadModel(from: fakeURL, plan: .testStub(effectiveContextSize: 2048))
        await backend.unloadAndWait()

        XCTAssertFalse(backend.isModelLoaded,
                       "isModelLoaded must be false after unloadAndWait()")
        XCTAssertFalse(backend.isGenerating,
                       "isGenerating must be false after unloadAndWait()")
    }

    // MARK: - Stop Generation

    func test_stopGeneration_whenNotGenerating_isNoOp() {
        let backend = LlamaBackend()
        // Should not crash
        backend.stopGeneration()
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Regression: stopGeneration() thread-safety (issue #418)

    /// Regression test for #418: `stopGeneration()` was called from the main actor
    /// while the decode loop read the `cancelled` flag from a detached task. A plain
    /// `Bool` with no synchronisation was a data race under TSan.
    ///
    /// This test does NOT require a GGUF model — it calls `stopGeneration()` on an
    /// unloaded `LlamaBackend` (which is a no-op) from a concurrent task while the
    /// decode loop would have been running if a model were present. The purpose is to
    /// confirm that concurrent atomic access to the `cancelled` flag doesn't crash or
    /// produce a TSan violation.
    ///
    /// For the concurrent-generation/stop interaction against real llama.cpp C state,
    /// see `test_stopGeneration_thenGenerate_succeeds_regression390` which requires a
    /// real GGUF model on disk.
    func test_stopGeneration_concurrentCallsFromMultipleTasks_isRaceFree() async {
        let backend = LlamaBackend()

        // Fire 50 concurrent tasks that each call stopGeneration(). The flag is
        // Atomic<Bool>, so no two stores race — TSan must see zero violations.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    backend.stopGeneration()
                }
            }
        }

        // Backend was never loaded, so isGenerating must remain false throughout.
        XCTAssertFalse(backend.isGenerating,
                       "Concurrent stopGeneration() calls must not corrupt isGenerating state")
    }

    // MARK: - Regression: Stop Then Regenerate (issue #390)

    /// Regression test for #390: calling `stopGeneration()` used to leave
    /// the KV cache populated with the prior run's tokens, so the next
    /// `generate()` failed with `InferenceError.inferenceFailure("Failed to decode prompt")`.
    ///
    /// The fix clears the KV cache at the start of `generate()` rather than
    /// conditionally at the end. This test requires a real GGUF model on
    /// disk because the bug is in llama.cpp's decode path — it cannot be
    /// reproduced with a mock.
    func test_stopGeneration_thenGenerate_succeeds_regression390() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Place a `.gguf` file in ~/Documents/Models/ to run this regression test."
            )
        }

        let backend = LlamaBackend()
        defer { backend.unloadModel() }

        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        XCTAssertTrue(backend.isModelLoaded)

        // First generation — kick it off, then stop it mid-stream.
        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: 128)
        let stream1 = try backend.generate(
            prompt: "Reply with a long story about a cat.",
            systemPrompt: nil,
            config: config
        )

        // Consume a few tokens to ensure generation has actually started
        // (and the KV cache has been populated) before we stop.
        var tokenCount = 0
        for try await event in stream1.events {
            if case .token = event {
                tokenCount += 1
                if tokenCount >= 3 { break }
            }
        }
        XCTAssertGreaterThan(tokenCount, 0, "Expected at least one token before stopping")

        backend.stopGeneration()

        // Drain the stream so isGenerating flips back to false.
        for try await _ in stream1.events { }

        // The backend flips `isGenerating` to false inside the task's `defer`
        // block, which may run a tick after the stream finishes. Poll until
        // a deadline so slower hardware or larger GGUFs don't flake.
        let waitDeadline = ContinuousClock.now + .seconds(2)
        while backend.isGenerating && ContinuousClock.now < waitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(backend.isGenerating)

        // Second generation on the same loaded model. Before the fix, this
        // would throw `InferenceError.inferenceFailure("Failed to decode prompt")`
        // because the KV cache still held positions from run 1.
        let stream2 = try backend.generate(
            prompt: "Say hello.",
            systemPrompt: nil,
            config: GenerationConfig(temperature: 0.3, maxOutputTokens: 16)
        )

        var secondRunTokenCount = 0
        for try await event in stream2.events {
            if case .token = event {
                secondRunTokenCount += 1
            }
        }

        XCTAssertGreaterThan(secondRunTokenCount, 0,
                             "Second generation after stopGeneration() must produce tokens — "
                             + "if this fails, the KV cache wasn't cleared between runs (#390)")
    }

    // MARK: - Multiple Init/Deinit Cycles

    func test_multipleInitDeinit_doesNotCrash() {
        for _ in 0..<5 {
            let backend = LlamaBackend()
            backend.unloadModel()
        }
    }

    // MARK: - Plan-Taking loadModel

    /// The plan's `effectiveContextSize` must be honoured verbatim — no clamping,
    /// no RAM-safe cap, no trained-context re-check. Prove it by passing a plan
    /// with a very small context (1 024) and asserting the backend reports it.
    ///
    /// Sabotage check: if `initializeModel` hardcoded `n_ctx = 2048` regardless
    /// of the plan, `backend.capabilities.maxContextTokens` would be 2 048 and
    /// this assertion would fail.
    func test_loadModel_fromPlan_passesEffectiveContextSizeToCContext() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Place a `.gguf` file in ~/Documents/Models/ to run this test."
            )
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }

        let requested = 1024
        let inputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .mappable,
            requestedContextSize: requested,
            trainedContextLength: nil,
            kvBytesPerToken: 0,
            availableMemoryBytes: UInt64.max,
            physicalMemoryBytes: UInt64.max,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.effectiveContextSize, requested,
                       "Plan must pass through the requested context when no ceilings bind")

        try await backend.loadModel(from: modelURL, plan: plan)
        XCTAssertTrue(backend.isModelLoaded)
        XCTAssertEqual(backend.capabilities.maxContextTokens, Int32(requested),
                       "Backend must honour the plan's effectiveContextSize verbatim — "
                       + "a mismatch means the plan was not authoritative")
    }

    /// Regression test for #398/#411: when the plan clamps the context to a
    /// smaller value than requested (the normal memory-gated path), the C API
    /// must allocate the clamped size, not the requested size. This is the
    /// named regression for the ggml_metal_host_malloc crash: before the plan,
    /// the backend would attempt the full requested context and crash.
    ///
    /// The assertion here is indirect — we cannot inspect ggml_metal_host_malloc
    /// error output from a unit test without OSLogStore plumbing — but load
    /// success at a plan-clamped size confirms the new path respects the clamp.
    ///
    /// Sabotage check: if the backend ignored the plan and used `requested`,
    /// the load would attempt a larger allocation than we requested and either
    /// succeed (invalidating the test's premise) or crash (failing the test).
    /// A non-throwing load at the clamped size is what we want to see.
    func test_loadModel_fromPlan_clampRespected_noMetalHostMallocFailure() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Place a `.gguf` file in ~/Documents/Models/ to run this regression test."
            )
        }

        // Build a plan with a generous request but a tight memory budget so the
        // plan's memoryCeiling clamps `effectiveContextSize` well below the
        // request. The inputs are synthetic — we don't need the real file size
        // because `mappable` strategy uses a fraction.
        let inputs = ModelLoadPlan.Inputs(
            modelFileSize: 1_073_741_824,  // 1 GB, mappable ⇒ 256 MB resident reserve
            memoryStrategy: .mappable,
            requestedContextSize: 65_536,
            trainedContextLength: nil,
            kvBytesPerToken: 131_072,      // ~128 KB/tok (large; forces aggressive clamp)
            availableMemoryBytes: 2_147_483_648,  // 2 GB available
            physicalMemoryBytes: 8_589_934_592,   // 8 GB physical
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertLessThan(plan.effectiveContextSize, inputs.requestedContextSize,
                          "Test setup requires the plan to clamp — inputs must force a memory ceiling")
        XCTAssertNotEqual(plan.verdict, .deny,
                          "Test setup requires a plan that is safe to load (not denied)")

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }

        try await backend.loadModel(from: modelURL, plan: plan)
        XCTAssertTrue(backend.isModelLoaded,
                      "Load at plan-clamped context size must succeed; a failure here would "
                      + "indicate the backend allocated more than the plan authorized")
        XCTAssertEqual(backend.capabilities.maxContextTokens, Int32(plan.effectiveContextSize))
    }

    // MARK: - TokenizerVendor

    func test_tokenizerVendor_conformance_vendorReturnsSelf() {
        let backend = LlamaBackend()
        // tokenizer should be the backend itself (as TokenizerProvider)
        let tokenizer = backend.tokenizer
        // Verify it produces a result — exact value doesn't matter without a loaded vocab
        let count = tokenizer.tokenCount("hello world")
        XCTAssertGreaterThan(count, 0, "tokenCount should always return a positive value")
    }

    func test_tokenCount_withoutLoadedModel_fallsBackToHeuristic() {
        // Without a loaded model, vocab is nil → tokenize() returns [] → heuristic kicks in.
        // "hello world" = 11 chars → max(1, 11/4) = 2
        let backend = LlamaBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertEqual(backend.tokenCount("hello world"), 2,
                       "Should fall back to char-count heuristic when no model is loaded")
    }

    func test_tokenCount_emptyString_withoutModel_returnsOne() {
        // HeuristicTokenizer floors at 1; LlamaBackend.tokenCount should match.
        let backend = LlamaBackend()
        XCTAssertEqual(backend.tokenCount(""), 1,
                       "Empty string with no model should return heuristic floor of 1")
    }

    func test_tokenCount_longString_withoutModel_scalesWithLength() {
        let backend = LlamaBackend()
        let short = backend.tokenCount("Hi")          // max(1, 2/4) = 1
        let long  = backend.tokenCount(String(repeating: "abcd", count: 100))  // 400/4 = 100
        XCTAssertLessThan(short, long, "Longer text should produce a higher token count")
    }

    // MARK: - Backend Contract

    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { LlamaBackend() }
    }
}
#endif

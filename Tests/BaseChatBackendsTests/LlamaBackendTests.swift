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
            try await backend.loadModel(from: fakeURL, contextSize: 2048)
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
        try await b.loadModel(from: url, contextSize: 2048)
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

    func test_contextSize_capLogic_ramSafeCapCalculation() {
        // Validates the RAM-safe cap formula used in loadModel without requiring a real model.
        // effectiveContextSize = min(requested, trainedContextLength, ramSafeCap)
        // where ramSafeCap = min(128_000, physicalMemory / (2 * 1024 * 4))
        //
        // On any modern Apple Silicon device this should yield a positive cap well
        // under 128_000 — confirming the formula doesn't overflow or produce zero.
        let availableRAM = Int64(ProcessInfo.processInfo.physicalMemory)
        let ramSafeCap = Int32(min(Int64(128_000), availableRAM / (2 * 1024 * 4)))
        XCTAssertGreaterThan(ramSafeCap, 0,
                             "RAM-safe cap must be positive; formula may have underflowed")
        XCTAssertLessThanOrEqual(ramSafeCap, 128_000,
                                 "RAM-safe cap must not exceed the absolute maximum of 128_000")
        // Also verify min() behaviour: a small requested size always wins
        let requested = Int32(512)
        let effective = min(requested, Int32(32_000), ramSafeCap)
        XCTAssertEqual(effective, requested,
                       "Requested context size should win when it is the smallest of the three values")
    }

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

        try? await backend.loadModel(from: fakeURL, contextSize: 2048)
        backend.unloadModel()

        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Stop Generation

    func test_stopGeneration_whenNotGenerating_isNoOp() {
        let backend = LlamaBackend()
        // Should not crash
        backend.stopGeneration()
        XCTAssertFalse(backend.isGenerating)
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

        try await backend.loadModel(from: modelURL, contextSize: 512)
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
        // block, which may run a tick after the stream finishes. Poll briefly.
        for _ in 0..<50 where backend.isGenerating {
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

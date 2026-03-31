#if MLX
import XCTest
import BaseChatCore
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for MLXBackend state, capabilities, and lifecycle.
///
/// Hardware-gated tests (those that require a real model load) are skipped in CI.
/// Full load→unload cycles are covered by `BaseChatE2ETests` on Apple Silicon.
final class MLXBackendTests: XCTestCase {

    // MARK: - State on Init (no hardware gate)

    func test_init_isNotLoaded() {
        let b = MLXBackend()
        XCTAssertFalse(b.isModelLoaded)
    }

    func test_init_isNotGenerating() {
        let b = MLXBackend()
        XCTAssertFalse(b.isGenerating)
    }

    // MARK: - Capabilities (no hardware gate)

    func test_capabilities_doesNotRequirePromptTemplate() {
        XCTAssertFalse(MLXBackend().capabilities.requiresPromptTemplate)
    }

    func test_capabilities_supportsSystemPrompt() {
        XCTAssertTrue(MLXBackend().capabilities.supportsSystemPrompt)
    }

    func test_capabilities_supportsTemperature() {
        XCTAssertTrue(MLXBackend().capabilities.supportedParameters.contains(.temperature))
    }

    func test_capabilities_contextSize() {
        XCTAssertEqual(MLXBackend().capabilities.maxContextTokens, 8192)
    }

    // MARK: - Lifecycle (no hardware gate)

    func test_generate_beforeLoad_throws() {
        XCTAssertThrowsError(
            try MLXBackend().generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        )
    }

    func test_unloadModel_beforeLoad_doesNotCrash() {
        MLXBackend().unloadModel()
    }

    func test_stopGeneration_beforeLoad_doesNotCrash() {
        MLXBackend().stopGeneration()
    }

    // MARK: - Hardware-gated

    func test_loadModel_invalidDirectory_throws() async throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "MLX requires Apple Silicon")
        let b = MLXBackend()
        let badURL = URL(fileURLWithPath: "/nonexistent-mlx-model-\(UUID().uuidString)")
        do {
            try await b.loadModel(from: badURL, contextSize: 512)
            XCTFail("Should throw for invalid model directory")
        } catch {
            XCTAssertFalse(b.isModelLoaded)
        }
    }

    func test_unloadModel_afterLoad_clearsState() async throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "MLX requires Apple Silicon")
        // Full load→unload→verify is covered in BaseChatE2ETests on Apple Silicon.
        throw XCTSkip("Full load→unload cycle covered in BaseChatE2ETests on Apple Silicon")
    }
}

// MARK: - Backend Contract

extension MLXBackendTests {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { MLXBackend() }
    }
}
#endif

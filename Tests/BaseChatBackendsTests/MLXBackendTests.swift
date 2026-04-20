#if MLX
import XCTest
import BaseChatCore
import BaseChatInference
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
            try await b.loadModel(from: badURL, plan: .testStub(effectiveContextSize: 512))
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

    // MARK: - Architecture preflight (no hardware gate)

    /// Writes a throwaway `config.json` into a temp directory so we can exercise
    /// `MLXBackend.validateArchitecture` without invoking the real MLX load path
    /// (which would trip the metallib guard in `swift test`).
    private func writeTempConfig(_ json: [String: Any]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-arch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: dir.appendingPathComponent("config.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func test_validateArchitecture_acceptsQwen3() throws {
        let url = try writeTempConfig(["model_type": "qwen3"])
        XCTAssertNoThrow(try MLXBackend.validateArchitecture(at: url))
    }

    func test_validateArchitecture_acceptsLlamaViaArchitectures() throws {
        // HF repos that omit `model_type` but ship `architectures: ["LlamaForCausalLM"]`
        // must still pass — snake_case prefix match keeps older snapshots working.
        let url = try writeTempConfig(["architectures": ["LlamaForCausalLM"]])
        XCTAssertNoThrow(try MLXBackend.validateArchitecture(at: url))
    }

    func test_validateArchitecture_rejectsVisionEncoder() throws {
        let url = try writeTempConfig(["model_type": "clip"])
        XCTAssertThrowsError(try MLXBackend.validateArchitecture(at: url)) { error in
            guard case InferenceError.unsupportedModelArchitecture(let arch) = error else {
                return XCTFail("Expected .unsupportedModelArchitecture, got \(error)")
            }
            XCTAssertEqual(arch, "clip")
        }
        // Sabotage confirmation: adding "clip" to `supportedLMArchitectures`
        // makes this assertion fail (no throw) — verified locally before commit.
    }

    func test_validateArchitecture_rejectsEmbeddings() throws {
        let url = try writeTempConfig(["model_type": "bert"])
        XCTAssertThrowsError(try MLXBackend.validateArchitecture(at: url)) { error in
            guard case InferenceError.unsupportedModelArchitecture = error else {
                return XCTFail("Expected .unsupportedModelArchitecture, got \(error)")
            }
        }
    }

    func test_validateArchitecture_rejectsVisionViaArchitectures() throws {
        // `model_type` missing, `architectures` says CLIPModel — must still be refused.
        let url = try writeTempConfig(["architectures": ["CLIPModel"]])
        XCTAssertThrowsError(try MLXBackend.validateArchitecture(at: url)) { error in
            guard case InferenceError.unsupportedModelArchitecture = error else {
                return XCTFail("Expected .unsupportedModelArchitecture, got \(error)")
            }
        }
    }

    func test_validateArchitecture_missingConfigIsNoOp() throws {
        // A directory with no config.json must not throw — the subsequent MLX load
        // path will surface the real "missing config" diagnostic instead.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-arch-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try MLXBackend.validateArchitecture(at: dir))
    }
}

// MARK: - Backend Contract

extension MLXBackendTests {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { MLXBackend() }
    }
}
#endif

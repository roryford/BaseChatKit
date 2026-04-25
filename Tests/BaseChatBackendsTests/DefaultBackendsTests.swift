import XCTest
import BaseChatCore
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

// MARK: - Pure Routing Tests (no hardware required)

/// Tests the pure routing functions in DefaultBackends.
/// These run in CI — no hardware, no backend instantiation.
final class DefaultBackendsRoutingTests: XCTestCase {

    func test_routing_gguf_mapsToLlamaBackend() {
        #if Llama
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .gguf), "LlamaBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .gguf))
        #endif
    }

    func test_routing_mlx_mapsToMLXBackend() {
        #if MLX
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .mlx), "MLXBackend")
        #else
        // MLX trait not enabled in this build — routing returns nil, which is correct.
        XCTAssertNil(DefaultBackends.backendTypeName(for: .mlx))
        #endif
    }

    func test_routing_foundation_mapsToFoundationBackend() {
        #if canImport(FoundationModels)
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .foundation), "FoundationBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .foundation))
        #endif
    }

    func test_routing_openAI_mapsToOpenAIBackend() {
        #if CloudSaaS
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .openAI), "OpenAIBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .openAI))
        #endif
    }

    func test_routing_claude_mapsToClaudeBackend() {
        #if CloudSaaS
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .claude), "ClaudeBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .claude))
        #endif
    }

    func test_routing_ollama_mapsToOllamaBackend() {
        #if Ollama
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .ollama), "OllamaBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .ollama))
        #endif
    }

    func test_routing_lmStudio_mapsToOpenAIBackend() {
        #if CloudSaaS
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .lmStudio), "OpenAIBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .lmStudio))
        #endif
    }

    func test_routing_custom_mapsToOpenAIBackend() {
        #if CloudSaaS
        XCTAssertEqual(DefaultBackends.backendTypeName(for: .custom), "OpenAIBackend")
        #else
        XCTAssertNil(DefaultBackends.backendTypeName(for: .custom))
        #endif
    }
}

// MARK: - Integration Tests (require hardware)

/// Tests that DefaultBackends.register completes without error and
/// that the resulting InferenceService can attempt model loads
/// (which exercises the factory lookup path).
///
/// Registration creates LlamaBackend instances, which require Apple Silicon.
@MainActor
final class DefaultBackendsTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "DefaultBackends registers LlamaBackend which requires Metal")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "DefaultBackends registers LlamaBackend which requires Apple Silicon")
    }

    func test_register_doesNotCrash() {
        let service = InferenceService()
        DefaultBackends.register(with: service)
        // If we get here, registration succeeded
    }

    func test_register_canBeCalledMultipleTimes() {
        let service = InferenceService()
        DefaultBackends.register(with: service)
        DefaultBackends.register(with: service)
        // Should not crash or corrupt state
    }

    #if Llama
    func test_loadModel_gguf_invalidPath_throwsModelLoadFailed() async {
        let service = InferenceService()
        DefaultBackends.register(with: service)

        let fakeModel = ModelInfo(
            name: "test",
            fileName: "nonexistent.gguf",
            url: URL(fileURLWithPath: "/tmp/nonexistent.gguf"),
            fileSize: 0,
            modelType: .gguf
        )

        do {
            try await service.loadModel(from: fakeModel, plan: .testStub(effectiveContextSize: 2048))
            XCTFail("Should throw for nonexistent GGUF file")
        } catch {
            // Expected — the factory created a LlamaBackend which failed to load
            XCTAssertFalse(service.isModelLoaded)
        }
    }
    #endif

    // Note: MLX backend tests require Xcode's Metal toolchain and cannot
    // run under `swift test`. Test MLX through the Xcode scheme instead.
}

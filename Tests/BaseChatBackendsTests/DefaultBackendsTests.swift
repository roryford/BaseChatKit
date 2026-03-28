import XCTest
import BaseChatCore
@testable import BaseChatBackends

/// Tests that DefaultBackends.register completes without error and
/// that the resulting InferenceService can attempt model loads
/// (which exercises the factory lookup path).
@MainActor
final class DefaultBackendsTests: XCTestCase {

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
            try await service.loadModel(from: fakeModel, contextSize: 2048)
            XCTFail("Should throw for nonexistent GGUF file")
        } catch {
            // Expected — the factory created a LlamaBackend which failed to load
            XCTAssertFalse(service.isModelLoaded)
        }
    }

    // Note: MLX backend tests require Xcode's Metal toolchain and cannot
    // run under `swift test`. Test MLX through the Xcode scheme instead.
}

import XCTest
import BaseChatCore
@testable import BaseChatBackends

/// Tests for LlamaBackend state, capabilities, and error handling.
///
/// These tests exercise everything that does not require a real GGUF model file:
/// init state, capabilities, error paths, lifecycle transitions, and stop/unload.
final class LlamaBackendTests: XCTestCase {

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

    // MARK: - Multiple Init/Deinit Cycles

    func test_multipleInitDeinit_doesNotCrash() {
        for _ in 0..<5 {
            let backend = LlamaBackend()
            backend.unloadModel()
        }
    }
}

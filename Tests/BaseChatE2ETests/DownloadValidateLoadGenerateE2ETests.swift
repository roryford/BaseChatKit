import XCTest
import Foundation
@testable import BaseChatCore
import BaseChatTestSupport

/// E2E test chaining the full model lifecycle: download files to disk,
/// validate them, load via a backend, and generate tokens.
///
/// Uses the real filesystem (temp directories) and `MockInferenceBackend`
/// so the test runs without hardware but exercises the real validation path.
final class DownloadValidateLoadGenerateE2ETests: XCTestCase {

    /// GGUF magic bytes: "GGUF" in ASCII.
    private static let ggufMagic: [UInt8] = [0x47, 0x47, 0x55, 0x46]

    private let fm = FileManager.default
    private let manager = BackgroundDownloadManager()

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("BaseChatE2E-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? fm.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - GGUF Lifecycle

    /// Full lifecycle: write GGUF file -> validate -> load backend -> generate tokens -> verify output.
    func test_gguf_downloadValidateLoadGenerate() async throws {
        // 1. Simulate a downloaded GGUF file with valid magic bytes and sufficient size.
        let modelURL = tempDir.appendingPathComponent("test-model.gguf")
        var data = Data(Self.ggufMagic)
        data.append(Data(repeating: 0xFF, count: 1_100_000))
        try data.write(to: modelURL)

        XCTAssertTrue(fm.fileExists(atPath: modelURL.path), "GGUF file must exist on disk")

        // 2. Validate the downloaded file through the real validation pipeline.
        XCTAssertNoThrow(
            try manager.validateDownloadedFile(at: modelURL, modelType: .gguf),
            "Valid GGUF file should pass validation"
        )

        // 3. Load the validated model into a mock backend.
        let backend = MockInferenceBackend()
        backend.tokensToYield = ["Once", " upon", " a", " time"]

        XCTAssertFalse(backend.isModelLoaded)
        try await backend.loadModel(from: modelURL, contextSize: 512)
        XCTAssertTrue(backend.isModelLoaded)
        XCTAssertEqual(backend.loadModelCallCount, 1)

        // 4. Generate tokens and collect the full output.
        let config = GenerationConfig(temperature: 0.7, maxTokens: 512)
        let stream = try backend.generate(
            prompt: "Tell me a story",
            systemPrompt: "You are a storyteller.",
            config: config
        )

        var output = ""
        for try await token in stream {
            output += token
        }

        // 5. Verify the generated output matches expected tokens.
        XCTAssertEqual(output, "Once upon a time")
        XCTAssertEqual(backend.generateCallCount, 1)
        XCTAssertEqual(backend.lastPrompt, "Tell me a story")
        XCTAssertEqual(backend.lastSystemPrompt, "You are a storyteller.")
        XCTAssertFalse(backend.isGenerating)
    }

    /// Lifecycle with an invalid GGUF file: validation should block the load step.
    func test_gguf_invalidFile_blocksLoad() async throws {
        // 1. Write a file with wrong magic bytes.
        let badModelURL = tempDir.appendingPathComponent("bad-model.gguf")
        var data = Data([0x00, 0x00, 0x00, 0x00])
        data.append(Data(repeating: 0xAA, count: 2_000_000))
        try data.write(to: badModelURL)

        // 2. Validation should reject the file.
        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: badModelURL, modelType: .gguf)
        ) { error in
            XCTAssertTrue(error is HuggingFaceError, "Expected HuggingFaceError, got \(type(of: error))")
        }

        // 3. Backend should never be loaded — verify by checking the mock was not called.
        let backend = MockInferenceBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertEqual(backend.loadModelCallCount, 0)
    }

    // MARK: - MLX Lifecycle

    /// Full lifecycle for MLX: write directory with config + weights -> validate -> load -> generate.
    func test_mlx_downloadValidateLoadGenerate() async throws {
        // 1. Simulate a downloaded MLX model directory.
        let mlxDir = tempDir.appendingPathComponent("test-model-mlx")
        try fm.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        let configPath = mlxDir.appendingPathComponent("config.json")
        try Data("{\"model_type\":\"llama\"}".utf8).write(to: configPath)

        let weightsPath = mlxDir.appendingPathComponent("model.safetensors")
        try Data(repeating: 0xAB, count: 1_000).write(to: weightsPath)

        XCTAssertTrue(fm.fileExists(atPath: configPath.path))
        XCTAssertTrue(fm.fileExists(atPath: weightsPath.path))

        // 2. Validate through the real pipeline.
        XCTAssertNoThrow(
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx),
            "Valid MLX directory should pass validation"
        )

        // 3. Load into mock backend.
        let backend = MockInferenceBackend()
        backend.tokensToYield = ["The", " answer", " is", " 42"]

        try await backend.loadModel(from: mlxDir, contextSize: 512)
        XCTAssertTrue(backend.isModelLoaded)

        // 4. Generate and collect output.
        let stream = try backend.generate(
            prompt: "What is the meaning of life?",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var output = ""
        for try await token in stream {
            output += token
        }

        XCTAssertEqual(output, "The answer is 42")
        XCTAssertEqual(backend.generateCallCount, 1)
    }

    // MARK: - Unload After Generate

    /// Verifies the full lifecycle including cleanup: load -> generate -> unload.
    func test_fullLifecycleWithUnload() async throws {
        // 1. Create a valid GGUF file.
        let modelURL = tempDir.appendingPathComponent("lifecycle-model.gguf")
        var data = Data(Self.ggufMagic)
        data.append(Data(repeating: 0xCC, count: 1_100_000))
        try data.write(to: modelURL)

        try manager.validateDownloadedFile(at: modelURL, modelType: .gguf)

        // 2. Load and generate.
        let backend = MockInferenceBackend()
        backend.tokensToYield = ["Done"]

        try await backend.loadModel(from: modelURL, contextSize: 512)
        XCTAssertTrue(backend.isModelLoaded)

        let stream = try backend.generate(
            prompt: "Test",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        var output = ""
        for try await token in stream {
            output += token
        }
        XCTAssertEqual(output, "Done")

        // 3. Unload and verify state is cleaned up.
        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
        XCTAssertEqual(backend.unloadCallCount, 1)

        // 4. Attempting to generate after unload should fail.
        XCTAssertThrowsError(
            try backend.generate(prompt: "Should fail", systemPrompt: nil, config: GenerationConfig())
        ) { error in
            // MockInferenceBackend throws InferenceError.inferenceFailure when no model is loaded.
            XCTAssertTrue(
                "\(error)".contains("No model loaded"),
                "Expected 'No model loaded' error, got: \(error)"
            )
        }
    }

    // MARK: - Sequential Load-Generate Cycles

    /// Verifies that the backend can be reloaded and used for multiple generation cycles.
    func test_multipleLoadGenerateCycles() async throws {
        let modelURL = tempDir.appendingPathComponent("multi-cycle.gguf")
        var data = Data(Self.ggufMagic)
        data.append(Data(repeating: 0xDD, count: 1_100_000))
        try data.write(to: modelURL)

        try manager.validateDownloadedFile(at: modelURL, modelType: .gguf)

        let backend = MockInferenceBackend()

        for cycle in 0..<3 {
            backend.tokensToYield = ["Cycle", " \(cycle)"]

            try await backend.loadModel(from: modelURL, contextSize: 512)
            XCTAssertTrue(backend.isModelLoaded)

            let stream = try backend.generate(
                prompt: "Cycle \(cycle)",
                systemPrompt: nil,
                config: GenerationConfig()
            )

            var output = ""
            for try await token in stream {
                output += token
            }
            XCTAssertEqual(output, "Cycle \(cycle)")

            backend.unloadModel()
            XCTAssertFalse(backend.isModelLoaded)
        }

        XCTAssertEqual(backend.loadModelCallCount, 3)
        XCTAssertEqual(backend.generateCallCount, 3)
        XCTAssertEqual(backend.unloadCallCount, 3)
    }
}

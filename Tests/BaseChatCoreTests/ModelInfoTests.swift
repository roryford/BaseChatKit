import XCTest
@testable import BaseChatCore

final class ModelInfoTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelInfoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - GGUF Initializer

    func test_ggufInit_validFile_createsModelInfo() throws {
        let fileURL = tempDirectory.appendingPathComponent("test-model.Q4_K_M.gguf")
        let data = Data(repeating: 0, count: 1024)
        try data.write(to: fileURL)

        let model = ModelInfo(ggufURL: fileURL)

        XCTAssertNotNil(model)
        XCTAssertEqual(model?.fileName, "test-model.Q4_K_M.gguf")
        XCTAssertEqual(model?.modelType, .gguf)
        XCTAssertEqual(model?.fileSize, 1024)
        XCTAssertEqual(model?.url, fileURL)
    }

    func test_ggufInit_nonGgufExtension_returnsNil() throws {
        let fileURL = tempDirectory.appendingPathComponent("not-a-model.txt")
        let data = Data(repeating: 0, count: 512)
        try data.write(to: fileURL)

        let model = ModelInfo(ggufURL: fileURL)

        XCTAssertNil(model)
    }

    func test_ggufInit_missingFile_returnsNil() {
        let fileURL = tempDirectory.appendingPathComponent("nonexistent.gguf")

        let model = ModelInfo(ggufURL: fileURL)

        XCTAssertNil(model)
    }

    // MARK: - MLX Initializer

    func test_mlxInit_validDirectory_createsModelInfo() throws {
        let mlxDir = tempDirectory.appendingPathComponent("test-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        let configData = Data("{}".utf8)
        try configData.write(to: mlxDir.appendingPathComponent("config.json"))

        let weightsData = Data(repeating: 0, count: 2048)
        try weightsData.write(to: mlxDir.appendingPathComponent("weights.safetensors"))

        let model = ModelInfo(mlxDirectory: mlxDir)

        XCTAssertNotNil(model)
        XCTAssertEqual(model?.modelType, .mlx)
        XCTAssertEqual(model?.fileName, "test-mlx-model")

        // Size should be the sum of config.json + weights.safetensors
        let expectedSize = UInt64(configData.count) + UInt64(weightsData.count)
        XCTAssertEqual(model?.fileSize, expectedSize)
    }

    func test_mlxInit_noConfigJson_returnsNil() throws {
        let mlxDir = tempDirectory.appendingPathComponent("bad-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        let weightsData = Data(repeating: 0, count: 1024)
        try weightsData.write(to: mlxDir.appendingPathComponent("weights.safetensors"))

        let model = ModelInfo(mlxDirectory: mlxDir)

        XCTAssertNil(model)
    }

    // MARK: - Memberwise Initializer

    func test_memberwiseInit_setsAllFields() {
        let id = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.gguf")

        let model = ModelInfo(
            id: id,
            name: "Test Model",
            fileName: "test.gguf",
            url: url,
            fileSize: 4096,
            modelType: .gguf
        )

        XCTAssertEqual(model.id, id)
        XCTAssertEqual(model.name, "Test Model")
        XCTAssertEqual(model.fileName, "test.gguf")
        XCTAssertEqual(model.url, url)
        XCTAssertEqual(model.fileSize, 4096)
        XCTAssertEqual(model.modelType, .gguf)
    }

    // MARK: - Backend Label

    func test_backendLabel_gguf_returnsGGUF() {
        let model = ModelInfo(
            name: "Test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 0,
            modelType: .gguf
        )

        XCTAssertEqual(model.backendLabel, "GGUF")
    }

    func test_backendLabel_mlx_returnsMLX() {
        let model = ModelInfo(
            name: "Test",
            fileName: "test-mlx",
            url: URL(fileURLWithPath: "/tmp/test-mlx"),
            fileSize: 0,
            modelType: .mlx
        )

        XCTAssertEqual(model.backendLabel, "MLX")
    }

    // MARK: - Display Name

    func test_displayName_stripsGgufExtension() throws {
        let fileURL = tempDirectory.appendingPathComponent("model-name.Q4_K_M.gguf")
        let data = Data(repeating: 0, count: 64)
        try data.write(to: fileURL)

        let model = ModelInfo(ggufURL: fileURL)

        XCTAssertEqual(model?.name, "model name.Q4 K M")
    }

    func test_displayName_mlxDirectory_formatsName() throws {
        let mlxDir = tempDirectory.appendingPathComponent("phi-3-mini-4bit")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))

        let model = ModelInfo(mlxDirectory: mlxDir)

        XCTAssertEqual(model?.name, "phi 3 mini 4bit")
    }
}

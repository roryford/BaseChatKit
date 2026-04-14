import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

final class ModelStorageServiceTests: XCTestCase {

    private var service: ModelStorageService!
    private var createdURLs: [URL]!
    private var sandbox: TestModelStorageSandbox!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try TestModelStorageSandbox(prefix: "ModelStorageServiceTests")
        service = sandbox.storageService
        createdURLs = []
        try service.ensureModelsDirectory()
    }

    override func tearDownWithError() throws {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs = nil
        service = nil
        sandbox.cleanup()
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Creates a temporary GGUF file inside the models directory with a UUID-based name.
    /// Returns the file URL. The file is tracked for tearDown cleanup.
    @discardableResult
    private func createGgufFile(named prefix: String = "test", size: Int = 1024) throws -> URL {
        let fileName = "\(prefix)-\(UUID().uuidString).gguf"
        let url = service.modelsDirectory.appendingPathComponent(fileName)
        var data = Data(ggufMagic)
        data.append(Data(repeating: 0xAA, count: max(size - data.count, 0)))
        try data.write(to: url)
        createdURLs.append(url)
        return url
    }

    /// Creates a temporary MLX directory with config.json inside the models directory.
    /// Returns the directory URL. The directory is tracked for tearDown cleanup.
    @discardableResult
    private func createMlxDirectory(named prefix: String = "mlx-model", weightsSize: Int = 2048) throws -> URL {
        let dirName = "\(prefix)-\(UUID().uuidString)"
        let url = service.modelsDirectory.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let configData = Data(#"{"model_type":"llama"}"#.utf8)
        try configData.write(to: url.appendingPathComponent("config.json"))

        let weightsData = Data(repeating: 0xBB, count: weightsSize)
        try weightsData.write(to: url.appendingPathComponent("weights.safetensors"))

        createdURLs.append(url)
        return url
    }

    /// Creates a non-model file inside the models directory.
    @discardableResult
    private func createNonModelFile(extension ext: String = "txt") throws -> URL {
        let fileName = "not-a-model-\(UUID().uuidString).\(ext)"
        let url = service.modelsDirectory.appendingPathComponent(fileName)
        try Data("hello".utf8).write(to: url)
        createdURLs.append(url)
        return url
    }

    // MARK: - ensureModelsDirectory

    func test_ensureModelsDirectory_createsDirectory() throws {
        // The directory may already exist from setUp; verify it exists after calling.
        try service.ensureModelsDirectory()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: service.modelsDirectory.path,
            isDirectory: &isDirectory
        )

        XCTAssertTrue(exists, "Models directory should exist")
        XCTAssertTrue(isDirectory.boolValue, "Models path should be a directory")
    }

    // MARK: - discoverModels

    func test_discoverModels_findsGgufFiles() throws {
        let ggufURL = try createGgufFile()

        let models = service.discoverModels()
        let match = models.first { $0.fileName == ggufURL.lastPathComponent }

        XCTAssertNotNil(match, "Should discover the GGUF file")
        XCTAssertEqual(match?.modelType, .gguf)
        XCTAssertEqual(match?.fileSize, 1024)
    }

    func test_discoverModels_findsMlxDirectories() throws {
        let mlxURL = try createMlxDirectory()

        let models = service.discoverModels()
        let match = models.first { $0.fileName == mlxURL.lastPathComponent }

        XCTAssertNotNil(match, "Should discover the MLX directory")
        XCTAssertEqual(match?.modelType, .mlx)
    }

    func test_discoverModels_ignoresNonModelFiles() throws {
        let nonModelURL = try createNonModelFile()

        let models = service.discoverModels()
        let match = models.first { $0.url == nonModelURL }

        XCTAssertNil(match, "Non-model files should not be discovered")
    }

    func test_discoverModels_emptyDirectory_returnsEmpty() throws {
        let models = service.discoverModels()
        XCTAssertTrue(models.isEmpty, "Empty isolated models directory should return no models")
    }

    func test_discoverModels_mixedFormats_findsBoth() throws {
        let ggufURL = try createGgufFile(named: "mixed-gguf")
        let mlxURL = try createMlxDirectory(named: "mixed-mlx")

        let models = service.discoverModels()
        let ggufMatch = models.first { $0.fileName == ggufURL.lastPathComponent }
        let mlxMatch = models.first { $0.fileName == mlxURL.lastPathComponent }

        XCTAssertNotNil(ggufMatch, "Should discover the GGUF file")
        XCTAssertNotNil(mlxMatch, "Should discover the MLX directory")
        XCTAssertEqual(ggufMatch?.modelType, .gguf)
        XCTAssertEqual(mlxMatch?.modelType, .mlx)
    }

    func test_discoverModels_sortedByName() throws {
        // Create files with names that sort in a known order.
        // Use a shared prefix so we can filter to just our test files.
        let tag = UUID().uuidString.prefix(8)
        let nameA = "aaa-\(tag)"
        let nameB = "bbb-\(tag)"
        let nameC = "ccc-\(tag)"

        // Create in reverse order to ensure sorting isn't just insertion order.
        try createGgufFile(named: nameC)
        try createGgufFile(named: nameA)
        try createGgufFile(named: nameB)

        let models = service.discoverModels()
        let taggedModels = models.filter { $0.fileName.contains(String(tag)) }

        XCTAssertEqual(taggedModels.count, 3, "Should find all three tagged models")
        XCTAssertTrue(
            taggedModels[0].name.localizedStandardCompare(taggedModels[1].name) == .orderedAscending,
            "First model should sort before second"
        )
        XCTAssertTrue(
            taggedModels[1].name.localizedStandardCompare(taggedModels[2].name) == .orderedAscending,
            "Second model should sort before third"
        )
    }

    // MARK: - deleteModel

    func test_deleteModel_removesFile() throws {
        let ggufURL = try createGgufFile()

        let models = service.discoverModels()
        let model = try XCTUnwrap(models.first { $0.fileName == ggufURL.lastPathComponent })

        try service.deleteModel(model)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ggufURL.path),
            "File should be deleted from disk"
        )

        // Remove from cleanup list since it's already deleted.
        createdURLs.removeAll { $0 == ggufURL }
    }

    // MARK: - modelStorageUsed

    func test_modelStorageUsed_sumsFileSizes() throws {
        let sizeA = 512
        let sizeB = 1024

        try createGgufFile(named: "sizeA", size: sizeA)
        try createGgufFile(named: "sizeB", size: sizeB)

        let totalUsed = service.modelStorageUsed()

        // The total must include at least our two files. Other models may already exist
        // in the directory, so we verify the total is >= our known sum.
        XCTAssertGreaterThanOrEqual(
            totalUsed,
            UInt64(sizeA + sizeB),
            "Storage used should include at least the sizes of our test files"
        )
    }

    // MARK: - importModel

    func test_importModel_copiesFileToModelsDirectory() throws {
        // Create a temporary file outside the models directory.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFileName = "import-test-\(UUID().uuidString).gguf"
        let sourceURL = tempDir.appendingPathComponent(sourceFileName)
        let data = Data(repeating: 0xCC, count: 2048)
        try data.write(to: sourceURL)

        let destination = try service.importModel(from: sourceURL)
        createdURLs.append(destination)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "Imported model should exist in models directory"
        )
        XCTAssertEqual(
            destination.lastPathComponent, sourceFileName,
            "Imported file should keep its original name"
        )

        // Verify file content was copied correctly.
        let copiedData = try Data(contentsOf: destination)
        XCTAssertEqual(copiedData.count, 2048, "Copied file should match source size")
    }

    func test_importModel_overwritesExisting() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwriteTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileName = "overwrite-test-\(UUID().uuidString).gguf"
        let sourceURL = tempDir.appendingPathComponent(fileName)

        // First import: 1024 bytes.
        try Data(repeating: 0xAA, count: 1024).write(to: sourceURL)
        let dest1 = try service.importModel(from: sourceURL)
        createdURLs.append(dest1)

        // Second import: 2048 bytes (overwrite).
        try Data(repeating: 0xBB, count: 2048).write(to: sourceURL)
        let dest2 = try service.importModel(from: sourceURL)

        XCTAssertEqual(dest1.path, dest2.path, "Both imports should target the same destination")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dest2.path),
            "File should still exist after overwrite"
        )

        let finalData = try Data(contentsOf: dest2)
        XCTAssertEqual(finalData.count, 2048, "Overwritten file should have the new size")
    }

    // MARK: - availableDiskSpace

    func test_availableDiskSpace_returnsNonZero() {
        let space = service.availableDiskSpace()

        XCTAssertGreaterThan(space, 0, "Available disk space should be non-zero on a real system")
    }
}

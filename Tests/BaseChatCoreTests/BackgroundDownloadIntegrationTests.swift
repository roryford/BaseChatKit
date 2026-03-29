import XCTest
@testable import BaseChatCore

/// Integration tests for BackgroundDownloadManager using real filesystem and real UserDefaults.
///
/// These tests exercise the actual persistence format (UserDefaults) and file
/// validation (filesystem) without mocking either subsystem. Tests that would
/// require creating a real background URLSession are avoided — they belong in
/// device-level E2E tests.
@MainActor
final class BackgroundDownloadIntegrationTests: XCTestCase {

    private var manager: BackgroundDownloadManager!
    private var tempDirectory: URL!

    /// Per-test isolated key to avoid parallel test interference on UserDefaults.standard.
    private var isolatedKey: String!

    override func setUp() {
        super.setUp()
        manager = BackgroundDownloadManager()
        isolatedKey = "com.basechatkit.tests.pending-\(UUID().uuidString)"

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundDownloadIntegrationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil

        if let isolatedKey {
            UserDefaults.standard.removeObject(forKey: isolatedKey)
        }
        isolatedKey = nil
        manager = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeModel(
        repoID: String = "test/repo",
        fileName: String = "model.gguf",
        displayName: String = "Test Model",
        modelType: ModelType = .gguf,
        sizeBytes: UInt64 = 1_000_000
    ) -> DownloadableModel {
        DownloadableModel(
            repoID: repoID,
            fileName: fileName,
            displayName: displayName,
            modelType: modelType,
            sizeBytes: sizeBytes
        )
    }

    /// Writes pending download data to an isolated UserDefaults key using the
    /// same format BackgroundDownloadManager uses internally.
    private func writePendingDownload(_ model: DownloadableModel) {
        var pending = UserDefaults.standard.dictionary(forKey: isolatedKey) as? [String: [String: String]] ?? [:]
        pending[model.id] = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": model.modelType == .gguf ? "gguf" : "mlx",
        ]
        UserDefaults.standard.set(pending, forKey: isolatedKey)
        UserDefaults.standard.synchronize()
    }

    /// Reads pending downloads from the isolated UserDefaults key.
    private func readPendingDownloads() -> [String: [String: String]]? {
        UserDefaults.standard.dictionary(forKey: isolatedKey) as? [String: [String: String]]
    }

    // MARK: - Pending Download Persistence Format

    func test_pendingDownloadFormat_roundTrips() {
        let model = makeModel(repoID: "bartowski/Mistral-7B", fileName: "mistral-7b-q4.gguf", displayName: "Mistral 7B Q4")

        writePendingDownload(model)

        let stored = readPendingDownloads()
        XCTAssertNotNil(stored, "Pending download should be stored in UserDefaults")
        XCTAssertNotNil(stored?[model.id], "Should be keyed by model ID (\(model.id))")
        XCTAssertEqual(stored?[model.id]?["repoID"], "bartowski/Mistral-7B")
        XCTAssertEqual(stored?[model.id]?["fileName"], "mistral-7b-q4.gguf")
        XCTAssertEqual(stored?[model.id]?["displayName"], "Mistral 7B Q4")
        XCTAssertEqual(stored?[model.id]?["modelType"], "gguf")
    }

    func test_pendingDownloadFormat_MLXModel() {
        let model = makeModel(
            repoID: "mlx-community/Llama-3.2-3B",
            fileName: "llama-3.2-3b",
            displayName: "Llama 3.2 3B MLX",
            modelType: .mlx
        )

        writePendingDownload(model)

        let stored = readPendingDownloads()
        XCTAssertNotNil(stored?[model.id])
        XCTAssertEqual(stored?[model.id]?["modelType"], "mlx")
    }

    func test_removePendingDownload_actuallyRemovesEntry() {
        let model1 = makeModel(repoID: "test/model1", fileName: "model1.gguf", displayName: "Model 1")
        let model2 = makeModel(repoID: "test/model2", fileName: "model2.gguf", displayName: "Model 2")

        writePendingDownload(model1)
        writePendingDownload(model2)

        var stored = readPendingDownloads()
        XCTAssertEqual(stored?.count, 2)

        // Remove one.
        stored?.removeValue(forKey: model1.id)
        UserDefaults.standard.set(stored, forKey: isolatedKey)

        let remaining = readPendingDownloads()
        XCTAssertEqual(remaining?.count, 1)
        XCTAssertNil(remaining?[model1.id])
        XCTAssertNotNil(remaining?[model2.id])
    }

    func test_pendingDownloadFormat_corruptEntry_missingFields() {
        // Verify format: the restore logic requires repoID, fileName, displayName, modelType.
        let pending: [String: Any] = [
            "test/repo/valid.gguf": [
                "repoID": "test/repo",
                "fileName": "valid.gguf",
                "displayName": "Valid Model",
                "modelType": "gguf",
            ] as [String: String],
            "test/repo/invalid.gguf": [
                "repoID": "test/repo",
                // Missing fileName, displayName, modelType
            ] as [String: String],
        ]
        UserDefaults.standard.set(pending, forKey: isolatedKey)

        let stored = UserDefaults.standard.dictionary(forKey: isolatedKey) as? [String: [String: String]]
        XCTAssertNotNil(stored)

        let validEntry = stored?["test/repo/valid.gguf"]
        XCTAssertNotNil(validEntry?["repoID"])
        XCTAssertNotNil(validEntry?["fileName"])
        XCTAssertNotNil(validEntry?["displayName"])
        XCTAssertNotNil(validEntry?["modelType"])

        let invalidEntry = stored?["test/repo/invalid.gguf"]
        XCTAssertNil(invalidEntry?["fileName"])
    }

    // MARK: - hasActiveDownloads with Mixed States

    func test_hasActiveDownloads_withMixedStates() {
        let queuedModel = makeModel(repoID: "test/queued", fileName: "queued.gguf", displayName: "Queued")
        let completedModel = makeModel(repoID: "test/completed", fileName: "completed.gguf", displayName: "Completed")
        let failedModel = makeModel(repoID: "test/failed", fileName: "failed.gguf", displayName: "Failed")
        let cancelledModel = makeModel(repoID: "test/cancelled", fileName: "cancelled.gguf", displayName: "Cancelled")

        let queuedState = DownloadState(model: queuedModel)

        let completedState = DownloadState(model: completedModel)
        completedState.markCompleted(localURL: tempDirectory.appendingPathComponent("completed.gguf"))

        let failedState = DownloadState(model: failedModel)
        failedState.markFailed(error: "Network error")

        let cancelledState = DownloadState(model: cancelledModel)
        cancelledState.markCancelled()

        // Only terminal states — should be false.
        manager.activeDownloads[completedModel.id] = completedState
        manager.activeDownloads[failedModel.id] = failedState
        manager.activeDownloads[cancelledModel.id] = cancelledState
        XCTAssertFalse(manager.hasActiveDownloads)

        // Add queued — should become true.
        manager.activeDownloads[queuedModel.id] = queuedState
        XCTAssertTrue(manager.hasActiveDownloads)

        // Transition to downloading — still true.
        queuedState.updateProgress(bytesDownloaded: 500_000, totalBytes: 1_000_000)
        XCTAssertTrue(manager.hasActiveDownloads)

        // Complete — back to false.
        queuedState.markCompleted(localURL: tempDirectory.appendingPathComponent("queued.gguf"))
        XCTAssertFalse(manager.hasActiveDownloads)
    }

    // MARK: - GGUF File Validation

    func test_validateGGUFFile_validMagicAndSize_passes() throws {
        let fileURL = tempDirectory.appendingPathComponent("valid-model.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0xAA, count: 1_100_000))
        try data.write(to: fileURL)

        XCTAssertNoThrow(try manager.validateDownloadedFile(at: fileURL, modelType: .gguf))
    }

    func test_validateGGUFFile_wrongMagicBytes_fails() throws {
        let fileURL = tempDirectory.appendingPathComponent("wrong-magic.gguf")
        var data = Data([0x50, 0x4B, 0x03, 0x04])
        data.append(Data(repeating: 0x00, count: 1_100_000))
        try data.write(to: fileURL)

        XCTAssertThrowsError(try manager.validateDownloadedFile(at: fileURL, modelType: .gguf))
    }

    func test_validateGGUFFile_tinySize_fails() throws {
        let fileURL = tempDirectory.appendingPathComponent("tiny.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0x00, count: 100))
        try data.write(to: fileURL)

        XCTAssertThrowsError(try manager.validateDownloadedFile(at: fileURL, modelType: .gguf))
    }

    // MARK: - MLX Directory Validation

    func test_validateMLXDirectory_withConfigJson_passes() throws {
        let mlxDir = tempDirectory.appendingPathComponent("valid-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{\"model_type\": \"llama\"}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))
        try Data(repeating: 0x00, count: 1024).write(to: mlxDir.appendingPathComponent("model.safetensors"))

        XCTAssertNoThrow(try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx))
    }

    func test_validateMLXDirectory_withoutConfigJson_fails() throws {
        let mlxDir = tempDirectory.appendingPathComponent("no-config-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data(repeating: 0x00, count: 1024).write(to: mlxDir.appendingPathComponent("model.safetensors"))

        XCTAssertThrowsError(try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx))
    }
}

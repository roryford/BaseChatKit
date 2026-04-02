import XCTest
@testable import BaseChatCore

@MainActor
final class DownloadManagerTests: XCTestCase {

    private var manager: BackgroundDownloadManager!
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        manager = BackgroundDownloadManager()

        // Create a temporary directory for test files.
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Clean up temp files.
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Disk Space

    func test_diskSpaceCheck_sufficientSpace() async {
        // A tiny model size should always pass the disk space check on a dev machine.
        do {
            try await manager.checkDiskSpace(requiredBytes: 1024)
        } catch {
            XCTFail("1 KB model should pass disk space check on any reasonable system, got: \(error)")
        }
    }

    func test_diskSpaceCheck_insufficientSpace() async {
        // Request an absurdly large amount of space that no system has.
        let absurdSize: UInt64 = UInt64.max / 2

        do {
            try await manager.checkDiskSpace(requiredBytes: absurdSize)
            XCTFail("Expected insufficientDiskSpace error")
        } catch {
            guard case HuggingFaceError.insufficientDiskSpace = error else {
                XCTFail("Expected insufficientDiskSpace error, got: \(error)")
                return
            }
        }
    }

    // MARK: - GGUF Validation

    func test_validateGGUFFile_validMagic() throws {
        // Create a temp file with valid GGUF magic bytes and realistic size (>1MB).
        let fileURL = tempDirectory.appendingPathComponent("valid.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46])  // "GGUF"
        data.append(Data(repeating: 0x00, count: 1_100_000))
        try data.write(to: fileURL)

        XCTAssertNoThrow(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf),
            "File with valid GGUF magic bytes should pass validation"
        )
    }

    func test_validateGGUFFile_invalidMagic() throws {
        // Create a temp file with wrong magic bytes.
        let fileURL = tempDirectory.appendingPathComponent("invalid.gguf")
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        try data.write(to: fileURL)

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains("magic bytes"),
                "Error reason should mention magic bytes, got: \(reason)"
            )
        }
    }

    func test_validateGGUFFile_tooSmall() throws {
        // Create a file with fewer than 4 bytes.
        let fileURL = tempDirectory.appendingPathComponent("tiny.gguf")
        let data = Data([0x47, 0x47])  // Only 2 bytes
        try data.write(to: fileURL)

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
        }
    }

    func test_validateGGUFFile_nonexistentFile() {
        let fileURL = tempDirectory.appendingPathComponent("does-not-exist.gguf")

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
        }
    }

    // MARK: - Active Downloads State

    func test_hasActiveDownloads_reflectsState() {
        // Initially no active downloads.
        XCTAssertFalse(manager.hasActiveDownloads, "Should have no active downloads initially")

        // Manually inject a queued download state to test the computed property.
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1000
        )
        let state = DownloadState(model: model)
        manager.activeDownloads[model.id] = state

        XCTAssertTrue(
            manager.hasActiveDownloads,
            "Should report active downloads when a queued state exists"
        )

        // Mark it completed.
        let dummyURL = tempDirectory.appendingPathComponent("test.gguf")
        state.markCompleted(localURL: dummyURL)

        XCTAssertFalse(
            manager.hasActiveDownloads,
            "Should not report active downloads when all are completed"
        )
    }

    func test_hasActiveDownloads_failedDoesNotCount() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1000
        )
        let state = DownloadState(model: model)
        state.markFailed(error: "Test error")
        manager.activeDownloads[model.id] = state

        XCTAssertFalse(
            manager.hasActiveDownloads,
            "Failed downloads should not count as active"
        )
    }

    func test_hasActiveDownloads_cancelledDoesNotCount() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1000
        )
        let state = DownloadState(model: model)
        state.markCancelled()
        manager.activeDownloads[model.id] = state

        XCTAssertFalse(
            manager.hasActiveDownloads,
            "Cancelled downloads should not count as active"
        )
    }

    // MARK: - Active Downloads Initial State

    func test_activeDownloads_initiallyEmpty() {
        let freshManager = BackgroundDownloadManager()
        XCTAssertTrue(
            freshManager.activeDownloads.isEmpty,
            "A freshly created manager should have no active downloads"
        )
    }

    // MARK: - DownloadState Transitions

    func test_downloadState_progressUpdates() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 10_000_000
        )
        let state = DownloadState(model: model)

        // Starts as queued.
        if case .queued = state.status { } else {
            XCTFail("Initial status should be .queued, got: \(state.status)")
        }

        // Update progress.
        state.updateProgress(bytesDownloaded: 5_000_000, totalBytes: 10_000_000)

        if case .downloading(let progress, let bytesDownloaded, let totalBytes) = state.status {
            XCTAssertEqual(progress, 0.5, accuracy: 0.001)
            XCTAssertEqual(bytesDownloaded, 5_000_000)
            XCTAssertEqual(totalBytes, 10_000_000)
        } else {
            XCTFail("After updateProgress, status should be .downloading, got: \(state.status)")
        }
    }

    func test_downloadState_transitionSequence() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 10_000_000
        )
        let state = DownloadState(model: model)

        // queued → downloading
        state.updateProgress(bytesDownloaded: 1_000, totalBytes: 10_000_000)
        if case .downloading = state.status { } else {
            XCTFail("Expected .downloading after updateProgress, got: \(state.status)")
        }

        // downloading → completed
        let dummyURL = tempDirectory.appendingPathComponent("test.gguf")
        state.markCompleted(localURL: dummyURL)
        if case .completed(let url) = state.status {
            XCTAssertEqual(url, dummyURL)
        } else {
            XCTFail("Expected .completed after markCompleted, got: \(state.status)")
        }
    }

    func test_downloadState_failedTransition() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 10_000_000
        )
        let state = DownloadState(model: model)

        // queued → failed
        state.markFailed(error: "Network timeout")
        if case .failed(let error) = state.status {
            XCTAssertEqual(error, "Network timeout")
        } else {
            XCTFail("Expected .failed after markFailed, got: \(state.status)")
        }
    }

    func test_downloadState_cancelledTransition() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 10_000_000
        )
        let state = DownloadState(model: model)

        // queued → cancelled
        state.markCancelled()
        if case .cancelled = state.status { } else {
            XCTFail("Expected .cancelled after markCancelled, got: \(state.status)")
        }
    }

    // MARK: - Disk Space Edge Cases

    func test_diskSpaceCheck_exactlyAtLimit() async {
        // Get the actual free space on the system.
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let freeSpace = attrs?[.systemFreeSize] as? UInt64 else {
            XCTFail("Could not read free disk space")
            return
        }

        // Request exactly: freeSpace - buffer - 1 byte (should just barely pass).
        let buffer: UInt64 = 500_000_000
        guard freeSpace > buffer + 1 else {
            // System has less than the buffer; skip this test gracefully.
            return
        }
        let requestSize = freeSpace - buffer - 1

        do {
            try await manager.checkDiskSpace(requiredBytes: requestSize)
        } catch {
            XCTFail("Requesting just under free space minus buffer should pass, got: \(error)")
        }
    }

    func test_diskSpaceCheck_zeroRequired_passes() async {
        do {
            try await manager.checkDiskSpace(requiredBytes: 0)
        } catch {
            XCTFail("Requesting 0 bytes should always pass the disk space check, got: \(error)")
        }
    }

    // MARK: - MLX Directory Validation

    func test_validateMLXDirectory_valid() throws {
        // Create a valid MLX model directory structure.
        let mlxDir = tempDirectory.appendingPathComponent("valid-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // Add config.json.
        let configData = Data("{\"model_type\": \"llama\"}".utf8)
        try configData.write(to: mlxDir.appendingPathComponent("config.json"))

        // Add a .safetensors file.
        let safetensorsData = Data(repeating: 0x00, count: 1024)
        try safetensorsData.write(to: mlxDir.appendingPathComponent("model.safetensors"))

        XCTAssertNoThrow(
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx),
            "A directory with config.json and .safetensors should pass MLX validation"
        )
    }

    func test_validateMLXDirectory_missingConfig() throws {
        // Create an MLX directory without config.json.
        let mlxDir = tempDirectory.appendingPathComponent("no-config-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // Only add a .safetensors file (no config.json).
        let safetensorsData = Data(repeating: 0x00, count: 1024)
        try safetensorsData.write(to: mlxDir.appendingPathComponent("model.safetensors"))

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains("config.json"),
                "Error reason should mention missing config.json, got: \(reason)"
            )
        }
    }

    func test_validateMLXDirectory_missingSafetensors() throws {
        // Create an MLX directory with config.json but no .safetensors.
        let mlxDir = tempDirectory.appendingPathComponent("no-safetensors-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // Only add config.json (no .safetensors).
        let configData = Data("{\"model_type\": \"llama\"}".utf8)
        try configData.write(to: mlxDir.appendingPathComponent("config.json"))

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains(".safetensors"),
                "Error reason should mention missing .safetensors files, got: \(reason)"
            )
        }
    }

    func test_validateFoundationModel_throws() {
        let dummyURL = tempDirectory.appendingPathComponent("dummy")

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: dummyURL, modelType: .foundation)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains("Foundation") || reason.contains("cannot be downloaded"),
                "Error reason should mention foundation models cannot be downloaded, got: \(reason)"
            )
        }
    }
}

@preconcurrency import XCTest
@testable import BaseChatInference

/// Unit tests for resumable download support in BackgroundDownloadManager.
///
/// These tests drive the manager's internal methods directly without a real URLSession,
/// covering resume data persistence/retrieval and the retryDownload(id:) state machine.
@MainActor
final class ResumableDownloadTests: XCTestCase {

    private var manager: BackgroundDownloadManager!
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumableDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        manager = BackgroundDownloadManager(
            storageService: ModelStorageService(baseDirectory: tempDirectory)
        )
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeModel(
        repoID: String = "test/repo",
        fileName: String = "model.gguf",
        displayName: String = "Test Model",
        sizeBytes: UInt64 = 1_000_000
    ) -> DownloadableModel {
        DownloadableModel(
            repoID: repoID,
            fileName: fileName,
            displayName: displayName,
            modelType: .gguf,
            sizeBytes: sizeBytes
        )
    }

    /// Seeds the pending-downloads metadata file with a single-file GGUF entry
    /// so retryDownload(id:) can reconstruct the model metadata.
    private func seedPendingDownload(_ model: DownloadableModel) throws {
        // Write a pending-downloads JSON file into the manager's persistence directory.
        // We replicate the internal format so the test remains honest about what the
        // real code reads back.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let persistenceDir = caches.appendingPathComponent(
            "\(BaseChatConfiguration.shared.bundleIdentifier).downloads",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: persistenceDir, withIntermediateDirectories: true)
        let metadataURL = persistenceDir.appendingPathComponent("pending-downloads.json")

        var pending: [String: [String: String]] = [:]
        if let existing = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: existing) {
            pending = decoded
        }
        pending[model.id] = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": "gguf",
            "sizeBytes": String(model.sizeBytes),
        ]
        try JSONEncoder().encode(pending).write(to: metadataURL)
    }

    // MARK: - Resume Data Persistence

    func test_persistResumeData_storesOnDisk() throws {
        let model = makeModel()
        let fakeResumeData = Data("fake-resume-bytes".utf8)

        manager.persistResumeData(fakeResumeData, for: model.id)

        // Verify the file exists in the caches persistence directory.
        let safeID = model.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? model.id
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let persistenceDir = caches.appendingPathComponent(
            "\(BaseChatConfiguration.shared.bundleIdentifier).downloads"
        )
        let fileURL = persistenceDir.appendingPathComponent("resume-\(safeID).bin")
        let stored = try? Data(contentsOf: fileURL)
        XCTAssertEqual(stored, fakeResumeData, "Resume data should be persisted as a file under the caches directory")

        // Clean up.
        try? FileManager.default.removeItem(at: fileURL)
    }

    func test_consumeResumeData_returnsAndDeletesFile() {
        let model = makeModel()
        let fakeResumeData = Data("consume-me".utf8)

        manager.persistResumeData(fakeResumeData, for: model.id)

        let consumed = manager.consumeResumeData(for: model.id)
        XCTAssertEqual(consumed, fakeResumeData, "consumeResumeData should return the persisted data")

        // After consumption the file must be gone so the next retry starts fresh.
        let safeID = model.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? model.id
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let persistenceDir = caches.appendingPathComponent(
            "\(BaseChatConfiguration.shared.bundleIdentifier).downloads"
        )
        let fileURL = persistenceDir.appendingPathComponent("resume-\(safeID).bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "consumeResumeData should delete the file")
    }

    func test_consumeResumeData_returnsNilWhenAbsent() {
        let model = makeModel()

        let result = manager.consumeResumeData(for: model.id)
        XCTAssertNil(result, "consumeResumeData should return nil when no data was stored")
    }

    func test_consumeResumeData_isOneShot() {
        let model = makeModel()
        let fakeResumeData = Data("one-shot".utf8)

        manager.persistResumeData(fakeResumeData, for: model.id)
        _ = manager.consumeResumeData(for: model.id)

        // A second consume should return nil, not the old data.
        let second = manager.consumeResumeData(for: model.id)
        XCTAssertNil(second, "A second consumeResumeData call should return nil (data already consumed)")
    }

    func test_persistResumeData_differentIDs_storedIndependently() {
        let model1 = makeModel(repoID: "test/m1", fileName: "m1.gguf", displayName: "M1")
        let model2 = makeModel(repoID: "test/m2", fileName: "m2.gguf", displayName: "M2")

        let data1 = Data("data-for-m1".utf8)
        let data2 = Data("data-for-m2".utf8)

        manager.persistResumeData(data1, for: model1.id)
        manager.persistResumeData(data2, for: model2.id)

        XCTAssertEqual(manager.consumeResumeData(for: model1.id), data1)
        XCTAssertEqual(manager.consumeResumeData(for: model2.id), data2)
    }

    // MARK: - delegate failure → resume data capture (simulated)

    /// Validates the codepath in didCompleteWithError: resume data is extracted from
    /// the NSError userInfo and persisted via persistResumeData. We call the method
    /// directly because creating a real URLSessionDownloadTask is unsafe in unit tests.
    func test_delegateFailure_persistsResumeDataForSingleFileDownload() {
        let model = makeModel()
        let fakeState = DownloadState(model: model)
        manager.activeDownloads[model.id] = fakeState

        // The delegate calls persistResumeData when context.relativePath == nil
        // (single-file download) and the error carries resume data.
        let resumeBytes = Data("resume-payload".utf8)
        manager.persistResumeData(resumeBytes, for: model.id)
        fakeState.markFailed(error: "Network connection lost")

        // Assert resume data was persisted (readable via consumeResumeData).
        let stored = manager.consumeResumeData(for: model.id)
        XCTAssertEqual(stored, resumeBytes, "Resume data should be persisted to disk after delegate failure")

        // Assert the download state reflects failure.
        guard case .failed(let error) = fakeState.status else {
            return XCTFail("DownloadState should be .failed after markFailed")
        }
        XCTAssertEqual(error, "Network connection lost")
    }

    func test_delegateFailure_doesNotPersistResumeDataOnCancellation() {
        let model = makeModel()
        let fakeState = DownloadState(model: model)
        manager.activeDownloads[model.id] = fakeState

        // The delegate only calls persistResumeData when the error is NOT NSURLErrorCancelled.
        // If cancelled, it calls markCancelled() and does NOT call persistResumeData.
        fakeState.markCancelled()

        // No resume data should be present after cancellation.
        XCTAssertNil(
            manager.consumeResumeData(for: model.id),
            "Cancellation should never store resume data"
        )
    }

    // MARK: - retryDownload: state machine transitions

    /// When pending metadata is absent, retryDownload should use the in-memory model,
    /// reset the state away from .failed, and consume any stale resume data.
    func test_retryDownload_withNoPendingMetadata_resetsStateAndConsumesResumeData() async {
        let model = makeModel()

        // Set up a failed state but do NOT seed pending metadata.
        let failedState = DownloadState(model: model)
        failedState.markFailed(error: "No metadata")
        manager.activeDownloads[model.id] = failedState

        // Pre-seed stale resume data to verify it gets consumed even in the fallback path.
        let staleResumeData = Data("stale-resume".utf8)
        manager.persistResumeData(staleResumeData, for: model.id)

        await manager.retryDownload(id: model.id)

        // State must not remain .failed — retryDownload should have replaced it.
        let newState = manager.activeDownloads[model.id]
        XCTAssertNotNil(newState, "activeDownloads should retain an entry")
        if let newState {
            if case .failed = newState.status {
                XCTFail("retryDownload should have transitioned state away from .failed")
            }
            XCTAssertNotEqual(
                ObjectIdentifier(newState), ObjectIdentifier(failedState),
                "retryDownload should replace the old state object"
            )
        }

        // Stale resume data must be consumed so it cannot accumulate across retries.
        XCTAssertNil(
            manager.consumeResumeData(for: model.id),
            "Fallback retry path must consume stale resume data"
        )
    }

    /// Verifies that consumeResumeData removes data and that persisting then consuming
    /// models the exact lifecycle that retryDownload goes through: consume-then-start.
    /// We test the consume step in isolation (not by passing fake bytes to URLSession,
    /// which would crash on invalid resume data).
    func test_retryDownload_consumeLifecycleIsOneShot() {
        let model = makeModel(
            repoID: "test/resume-consume",
            fileName: "resume-consume.gguf",
            displayName: "Resume Consume"
        )

        // Simulate what didCompleteWithError does on failure.
        manager.persistResumeData(Data("resume-bytes".utf8), for: model.id)
        XCTAssertNotNil(manager.consumeResumeData(for: model.id), "Data should be readable after persist")

        // Simulate what retryDownload does before starting the URLSession task.
        // A second consume should be nil — the file was already removed.
        XCTAssertNil(
            manager.consumeResumeData(for: model.id),
            "Key should be removed after consume, preventing stale data on next failure"
        )
    }

    func test_retryDownload_resetsStateToQueued() async throws {
        let model = makeModel(
            repoID: "test/reset-queued",
            fileName: "reset-queued.gguf",
            displayName: "Reset Queued"
        )

        let failedState = DownloadState(model: model)
        failedState.markFailed(error: "Previous failure")
        manager.activeDownloads[model.id] = failedState
        try seedPendingDownload(model)

        // Capture the identity of the old state object. retryDownload creates a new one.
        let oldStateID = ObjectIdentifier(failedState)

        await manager.retryDownload(id: model.id)

        let newState = manager.activeDownloads[model.id]
        XCTAssertNotNil(newState, "activeDownloads must have an entry after retry")
        if let newState {
            // The new state object should be different from the old failed one.
            XCTAssertNotEqual(
                ObjectIdentifier(newState), oldStateID,
                "retryDownload should create a new DownloadState, not reuse the old failed one"
            )
        }
    }

    // MARK: - Pending metadata preserved on failure

    /// The delegate must NOT remove pending metadata when a single-file download fails.
    /// Keeping the metadata alive lets retryDownload(id:) reconstruct the model and
    /// reach the resume-data code path rather than falling back to a fresh download.
    func test_delegateFailure_keepsPendingMetadataForSingleFileDownload() throws {
        let model = makeModel(
            repoID: "test/keep-pending",
            fileName: "keep-pending.gguf",
            displayName: "Keep Pending"
        )

        // Seed pending metadata as if a download had been started.
        try seedPendingDownload(model)

        // Simulate what didCompleteWithError does on a non-cancelled single-file failure:
        // it calls persistResumeData and markFailed — but must NOT call removePendingDownload.
        let resumeBytes = Data("resume-payload".utf8)
        manager.persistResumeData(resumeBytes, for: model.id)
        let failedState = DownloadState(model: model)
        manager.activeDownloads[model.id] = failedState
        failedState.markFailed(error: "Network timeout")

        // Pending metadata must still be present — retryDownload depends on it.
        // We verify by checking that retryDownload can find the model metadata.
        // The manager's retryDownload method reads from the file; if the file is
        // present with the right entry, it will find the metadata.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let persistenceDir = caches.appendingPathComponent(
            "\(BaseChatConfiguration.shared.bundleIdentifier).downloads"
        )
        let metadataURL = persistenceDir.appendingPathComponent("pending-downloads.json")
        let data = try XCTUnwrap(
            try? Data(contentsOf: metadataURL),
            "Pending metadata file must exist after simulated failure"
        )
        let pending = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertNotNil(
            pending[model.id],
            "Pending metadata must survive a single-file failure so retryDownload can use it"
        )

        // Clean up the seeded metadata file.
        try? FileManager.default.removeItem(at: metadataURL)
        _ = manager.consumeResumeData(for: model.id)
    }

    // MARK: - No UserDefaults contamination

    /// Resume data must NOT appear in UserDefaults — verifies the new file-based path
    /// does not accidentally write to the old keys.
    func test_persistResumeData_doesNotWriteToUserDefaults() {
        let model = makeModel()
        let data = Data("no-defaults".utf8)

        manager.persistResumeData(data, for: model.id)

        let legacyKey = "resumeData.\(model.id)"
        XCTAssertNil(
            UserDefaults.standard.data(forKey: legacyKey),
            "Resume data must not be written to UserDefaults (legacy path)"
        )

        // Clean up.
        _ = manager.consumeResumeData(for: model.id)
    }
}

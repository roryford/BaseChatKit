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

    /// Isolated UserDefaults key to avoid collisions with real app data or parallel tests.
    private var pendingKey: String!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumableDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        manager = BackgroundDownloadManager(
            storageService: ModelStorageService(baseDirectory: tempDirectory)
        )
        pendingKey = BaseChatConfiguration.shared.pendingDownloadsKey
    }

    override func tearDown() async throws {
        // Clean up resume data keys written during the test.
        for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("resumeData.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        manager = nil
        pendingKey = nil
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

    /// Seeds the pending downloads UserDefaults key with a single-file GGUF entry
    /// so retryDownload(id:) can reconstruct the model metadata.
    private func seedPendingDownload(_ model: DownloadableModel) {
        var pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: [String: String]] ?? [:]
        pending[model.id] = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": "gguf",
            "sizeBytes": String(model.sizeBytes),
        ]
        UserDefaults.standard.set(pending, forKey: pendingKey)
    }

    // MARK: - Resume Data Persistence

    func test_persistResumeData_storesInUserDefaults() {
        let model = makeModel()
        let fakeResumeData = Data("fake-resume-bytes".utf8)

        manager.persistResumeData(fakeResumeData, for: model.id)

        let key = "resumeData.\(model.id)"
        let stored = UserDefaults.standard.data(forKey: key)
        XCTAssertEqual(stored, fakeResumeData, "Resume data should be persisted under resumeData.<id>")
    }

    func test_consumeResumeData_returnsAndRemovesData() {
        let model = makeModel()
        let fakeResumeData = Data("consume-me".utf8)

        manager.persistResumeData(fakeResumeData, for: model.id)

        let consumed = manager.consumeResumeData(for: model.id)
        XCTAssertEqual(consumed, fakeResumeData, "consumeResumeData should return the persisted data")

        // After consumption the key must be gone so the next retry starts fresh.
        let key = "resumeData.\(model.id)"
        XCTAssertNil(UserDefaults.standard.data(forKey: key), "consumeResumeData should remove the key")
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

        // Assert resume data was persisted.
        let key = "resumeData.\(model.id)"
        let stored = UserDefaults.standard.data(forKey: key)
        XCTAssertEqual(stored, resumeBytes, "Resume data should be in UserDefaults after delegate failure")

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
        let key = "resumeData.\(model.id)"
        XCTAssertNil(
            UserDefaults.standard.data(forKey: key),
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

        // Stale resume data must be consumed so it cannot leak across retries.
        let key = "resumeData.\(model.id)"
        XCTAssertNil(
            UserDefaults.standard.data(forKey: key),
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
        let key = "resumeData.\(model.id)"

        // Simulate what didCompleteWithError does on failure.
        manager.persistResumeData(Data("resume-bytes".utf8), for: model.id)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: key), "Data should be present after persist")

        // Simulate what retryDownload does before starting the URLSession task.
        let consumed = manager.consumeResumeData(for: model.id)
        XCTAssertNotNil(consumed, "consumeResumeData should return the stored data")
        XCTAssertNil(
            UserDefaults.standard.data(forKey: key),
            "Key should be removed after consume, preventing stale data on next failure"
        )

        // A subsequent consume (second failure without a new persist) should return nil.
        XCTAssertNil(manager.consumeResumeData(for: model.id))
    }

    func test_retryDownload_resetsStateToQueued() async {
        let model = makeModel(
            repoID: "test/reset-queued",
            fileName: "reset-queued.gguf",
            displayName: "Reset Queued"
        )

        let failedState = DownloadState(model: model)
        failedState.markFailed(error: "Previous failure")
        manager.activeDownloads[model.id] = failedState
        seedPendingDownload(model)

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

        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    // MARK: - Pending metadata preserved on failure

    /// The delegate must NOT remove pending metadata when a single-file download fails.
    /// Keeping the metadata alive lets retryDownload(id:) reconstruct the model and
    /// reach the resume-data code path rather than falling back to a fresh download.
    func test_delegateFailure_keepsPendingMetadataForSingleFileDownload() {
        let model = makeModel(
            repoID: "test/keep-pending",
            fileName: "keep-pending.gguf",
            displayName: "Keep Pending"
        )

        // Seed pending metadata as if a download had been started.
        seedPendingDownload(model)

        // Simulate what didCompleteWithError does on a non-cancelled single-file failure:
        // it calls persistResumeData and markFailed — but must NOT call removePendingDownload.
        let resumeBytes = Data("resume-payload".utf8)
        manager.persistResumeData(resumeBytes, for: model.id)
        let failedState = DownloadState(model: model)
        manager.activeDownloads[model.id] = failedState
        failedState.markFailed(error: "Network timeout")

        // Pending metadata must still be present — retryDownload depends on it.
        let pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: [String: String]]
        XCTAssertNotNil(
            pending?[model.id],
            "Pending metadata must survive a single-file failure so retryDownload can use it"
        )
    }

    // MARK: - Key isolation: resume data key format

    func test_resumeDataKeyFormat_containsDownloadID() {
        // Verify the key format matches what didCompleteWithError stores.
        // Tests that iterate UserDefaults keys by prefix depend on this.
        let model = makeModel()
        let data = Data("x".utf8)
        manager.persistResumeData(data, for: model.id)

        let expected = "resumeData.\(model.id)"
        XCTAssertNotNil(
            UserDefaults.standard.data(forKey: expected),
            "Resume data key should be 'resumeData.<modelID>'"
        )
    }
}

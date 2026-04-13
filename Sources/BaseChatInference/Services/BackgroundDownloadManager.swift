import Foundation
import os

/// Manages background downloads of model files using `URLSession` background transfers.
///
/// Handles disk space checks, download progress tracking, file validation (GGUF magic
/// bytes), and moving completed files into the models directory. Designed to survive
/// app suspension on iOS — `URLSessionConfiguration.background` ensures the system
/// continues downloads even when the app is not in the foreground.
///
/// This class is `@Observable` so the UI can bind to `activeDownloads` for live progress.
/// Because `URLSessionDownloadDelegate` callbacks arrive on the session's delegate queue
/// (not the main thread), state mutations are dispatched to `@MainActor`.
@Observable
public final class BackgroundDownloadManager: NSObject, @unchecked Sendable {

    // MARK: - Constants

    /// The background URL session identifier (derived from BaseChatConfiguration).
    public static var sessionIdentifier: String {
        BaseChatConfiguration.shared.downloadSessionIdentifier
    }

    /// Minimum free disk space buffer beyond the model size (500 MB).
    private static let diskSpaceBuffer: UInt64 = 500_000_000

    // MARK: - Observable State

    /// Active and recently completed downloads, keyed by `DownloadableModel.id`.
    ///
    /// Setter is `internal` (not `private`) so tests can inject state via `@testable import`.
    public internal(set) var activeDownloads: [String: DownloadState] = [:]

    /// Whether any download is currently queued or actively transferring data.
    ///
    /// Returns `true` if at least one entry in ``activeDownloads`` has a status of
    /// `.queued` or `.downloading`. Completed, failed, and cancelled downloads are
    /// not counted.
    public var hasActiveDownloads: Bool {
        activeDownloads.values.contains { state in
            switch state.status {
            case .queued, .downloading:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
    }

    // MARK: - Private State

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    internal struct TaskContext: Codable, Sendable {
        let modelID: String
        let relativePath: String?
        let expectedBytes: Int64
    }

    private struct SnapshotFileMetadata: Codable, Sendable {
        let relativePath: String
        let sizeBytes: UInt64
    }

    private struct SnapshotProgress: Sendable {
        var bytesDownloaded: Int64
        var expectedBytes: Int64
    }

    private struct SnapshotDownloadContext: Sendable {
        let stagingDirectory: URL
        let files: [String: SnapshotFileMetadata]
        let totalBytes: Int64
        var progressByFile: [String: SnapshotProgress]
        var completedFiles: Set<String>
        var taskIDs: Set<Int>
        /// Set to true when a cancellation is in progress; lets delegate callbacks
        /// drain without racing into .failed state before all tasks have reported back.
        var isCancelling: Bool = false
    }

    /// Maps `URLSessionTask.taskIdentifier` to task metadata for delegate routing.
    private var taskContexts: [Int: TaskContext] = [:]

    /// Tracks multi-file MLX downloads by logical model ID.
    private var snapshotDownloads: [String: SnapshotDownloadContext] = [:]

    /// Promoted to `internal` (from `private`) so `BackgroundDownloadManager+URLSessionDelegate.swift`
    /// can read `storageService.modelsDirectory` when moving completed downloads.
    internal let storageService: ModelStorageService

    /// Backing store for the lazily created background URL session.
    ///
    /// Kept as an optional so `deinit` can skip invalidation when the session
    /// was never created (e.g. in unit tests that never start a download).
    /// Accessing `backgroundSession` during `deinit` before the object has fully
    /// initialised its memory is unsafe and causes a SIGSEGV.
    @ObservationIgnored
    private var _backgroundSession: URLSession?

    /// Lazily created background URL session.
    ///
    /// Marked `@ObservationIgnored` because `@Observable` does not support stored
    /// computed-like properties that hold references.
    @ObservationIgnored
    private var backgroundSession: URLSession {
        if let existing = _backgroundSession { return existing }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Allow cellular for user-initiated downloads.
        config.allowsCellularAccess = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _backgroundSession = session
        return session
    }

    // MARK: - File-based Persistence

    /// Directory in Caches where we store the pending-downloads JSON and per-download
    /// resume-data files. Using Caches lets the OS reclaim space under extreme pressure,
    /// which is acceptable — a missing resume-data file causes a fresh download, not a
    /// crash or data corruption.
    private var persistenceDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(
            "\(BaseChatConfiguration.shared.bundleIdentifier).downloads",
            isDirectory: true
        )
    }

    /// URL of the single JSON file that stores all pending-download metadata.
    private var pendingMetadataFileURL: URL {
        persistenceDirectory.appendingPathComponent("pending-downloads.json")
    }

    /// URL of the resume-data binary file for a given download ID.
    private func resumeDataFileURL(for id: String) -> URL {
        // URL-encode the ID so that slash-separated repo paths (e.g. "user/repo/file.gguf")
        // don't create subdirectories inside the persistence directory.
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return persistenceDirectory.appendingPathComponent("resume-\(safeID).bin")
    }

    /// Ensures the persistence directory exists, creating it if necessary.
    private func ensurePersistenceDirectory() throws {
        try FileManager.default.createDirectory(
            at: persistenceDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Init

    public init(storageService: ModelStorageService = ModelStorageService()) {
        self.storageService = storageService
        super.init()
    }

    deinit {
        _backgroundSession?.invalidateAndCancel()
    }

    // MARK: - Public API

    /// Starts a background download for the given model.
    ///
    /// - Parameters:
    ///   - model: The model to download.
    ///   - downloadURL: The direct URL to download the file from.
    /// - Returns: The `DownloadState` that the UI should observe for progress.
    /// - Throws: `HuggingFaceError.insufficientDiskSpace` if there isn't enough room.
    @MainActor @discardableResult
    public func startDownload(_ model: DownloadableModel, downloadURL: URL) async throws -> DownloadState {
        try await startDownload(model, plan: .singleFile(url: downloadURL))
    }

    /// Starts a background download using a resolved download plan.
    @MainActor @discardableResult
    public func startDownload(_ model: DownloadableModel, plan: ModelDownloadPlan) async throws -> DownloadState {
        try await checkDiskSpace(requiredBytes: model.sizeBytes)
        try storageService.ensureModelsDirectory()

        let state = DownloadState(model: model)
        activeDownloads[model.id] = state

        switch plan {
        case .singleFile(let url):
            Log.download.info("Starting single-file download for \(model.displayName) from \(url)")
            try startSingleFileDownload(model: model, url: url)
        case .snapshot(let files):
            Log.download.info("Starting snapshot download for \(model.displayName) with \(files.count) files")
            try startSnapshotDownload(model: model, files: files)
        }

        return state
    }

    /// Retries a failed download, resuming from where it left off when possible.
    ///
    /// If resume data was persisted when the previous attempt failed, the download
    /// restarts from the byte offset that was already transferred. When the server
    /// rejects stale resume data the method transparently falls back to a fresh
    /// download from the original URL.
    ///
    /// - Parameter id: The `DownloadableModel.id` of the failed download to retry.
    @MainActor public func retryDownload(id: String) async {
        // Retrieve the persisted model metadata needed to restart the download.
        guard let pending = loadPendingMetadata(),
              let info = pending[id],
              let repoID = info["repoID"],
              let fileName = info["fileName"],
              let displayName = info["displayName"],
              let typeStr = info["modelType"] else {
            // Fall back to the existing failed state's model when metadata is absent.
            // This should be rare — pending metadata is now kept alive until a successful
            // retry or explicit removal. The guard covers true edge cases (e.g. corrupt
            // pending metadata file, or the model was deleted between failure and retry tap).
            guard let existingState = activeDownloads[id] else {
                Log.download.error("retryDownload called for unknown download ID: \(id)")
                return
            }
            let model = existingState.model
            // Reset state so the UI transitions away from .failed immediately.
            activeDownloads[model.id] = DownloadState(model: model)
            // Consume any stale resume data so it doesn't accumulate on disk.
            _ = consumeResumeData(for: id)
            await retryWithFreshDownload(model: model)
            return
        }

        let modelType: ModelType = typeStr == "gguf" ? .gguf : .mlx
        let sizeBytes = UInt64(info["sizeBytes"] ?? "") ?? 0
        let model = DownloadableModel(
            repoID: repoID,
            fileName: fileName,
            displayName: displayName,
            modelType: modelType,
            sizeBytes: sizeBytes
        )

        // Reset to queued so the UI reflects that a new attempt is underway.
        let state = DownloadState(model: model)
        activeDownloads[model.id] = state

        // Consume any persisted resume data. Clean it up regardless of outcome so
        // we never retry with stale data on a subsequent failure.
        let resumeData = consumeResumeData(for: id)

        if let resumeData {
            Log.download.info("Retrying download \(id) with resume data (\(resumeData.count) bytes)")
            let task = backgroundSession.downloadTask(withResumeData: resumeData)
            let context = TaskContext(
                modelID: model.id,
                relativePath: nil,
                expectedBytes: Int64(sizeBytes)
            )
            task.taskDescription = encodeTaskDescription(context)
            taskContexts[task.taskIdentifier] = context
            do {
                try savePendingDownload(model: model)
            } catch {
                Log.download.error("Failed to persist retry download for \(id): \(error.localizedDescription)")
            }
            task.resume()
        } else {
            Log.download.info("Retrying download \(id) from scratch (no resume data)")
            await retryWithFreshDownload(model: model)
        }
    }

    /// Starts a fresh single-file download for a model from its HuggingFace URL.
    ///
    /// Used as the fallback when resume data is absent or rejected by the server.
    @MainActor private func retryWithFreshDownload(model: DownloadableModel) async {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        let segments = ([model.repoID, "resolve", "main"] + model.fileName.components(separatedBy: "/"))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        guard let url = components.url else {
            Log.download.error("Failed to build retry URL for \(model.id)")
            activeDownloads[model.id]?.markFailed(error: "Could not construct download URL for retry")
            return
        }
        do {
            try startSingleFileDownload(model: model, url: url)
        } catch {
            Log.download.error("Failed to start fresh retry download for \(model.id): \(error.localizedDescription)")
            activeDownloads[model.id]?.markFailed(error: error.localizedDescription)
        }
    }

    /// Cancels an in-progress download.
    ///
    /// - Parameter id: The `DownloadableModel.id` of the download to cancel.
    @MainActor public func cancelDownload(id: String) {
        Log.download.info("Cancelling download: \(id)")

        // getAllTasks delivers its callback on the URLSession delegate queue (a background
        // thread). Reading taskContexts — which is written from @MainActor — on that queue
        // is a data race. We hop back to @MainActor for the dictionary read, match tasks
        // by model ID, and then cancel them. URLSessionTask.cancel() is thread-safe.
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for task in tasks {
                    let context = self.taskContext(
                        for: task.taskIdentifier,
                        taskDescription: task.taskDescription
                    )
                    if context?.modelID == id {
                        task.cancel()
                    }
                }
                self.activeDownloads[id]?.markCancelled()
                self.removePendingDownload(id: id)
                // Mark the snapshot as cancelling rather than removing it immediately.
                // URLSession delegate callbacks can still arrive after task.cancel() is
                // called; deferring cleanup here prevents a cancelled download from
                // transitioning to .failed due to a "missing snapshot context" error.
                if self.snapshotDownloads[id] != nil {
                    self.snapshotDownloads[id]?.isCancelling = true
                }
            }
        }
    }

    /// Re-creates the background session to pick up any downloads that completed
    /// while the app was suspended or terminated.
    ///
    /// Call this on app launch (e.g., from the `App` struct's `init`).
    @MainActor public func reconnectBackgroundSession() {
        Log.download.info("Reconnecting background session")
        // Simply accessing the lazy session property re-creates it, which causes
        // the system to deliver any pending delegate callbacks.
        _ = backgroundSession

        // Re-populate activeDownloads from persisted pending downloads.
        restorePendingDownloads()
    }

    // MARK: - Disk Space

    /// Checks that there is enough free disk space for the download plus a safety buffer.
    ///
    /// Performs the filesystem query on a background thread to avoid blocking the main thread.
    public func checkDiskSpace(requiredBytes: UInt64) async throws {
        let (freeSpace, needed) = try await Task.detached {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let free = attrs[.systemFreeSize] as? UInt64 ?? 0
            return (free, requiredBytes + Self.diskSpaceBuffer)
        }.value

        guard freeSpace > needed else {
            Log.download.error(
                "Insufficient disk space: need \(needed) bytes, have \(freeSpace)"
            )
            throw HuggingFaceError.insufficientDiskSpace(
                required: needed,
                available: freeSpace
            )
        }
    }

    // MARK: - File Validation

    /// Validates that a downloaded file has the correct format.
    ///
    /// Delegates to ``DownloadFileValidator`` which contains the format-specific logic.
    ///
    /// - Parameters:
    ///   - fileURL: The temporary file location from URLSession.
    ///   - modelType: The expected model type.
    /// - Throws: `HuggingFaceError.invalidDownloadedFile` if validation fails.
    public func validateDownloadedFile(at fileURL: URL, modelType: ModelType) throws {
        try DownloadFileValidator().validate(at: fileURL, modelType: modelType)
    }

    // MARK: - Download Coordination

    @MainActor
    private func startSingleFileDownload(model: DownloadableModel, url: URL) throws {
        let task = backgroundSession.downloadTask(with: url)
        let context = TaskContext(
            modelID: model.id,
            relativePath: nil,
            expectedBytes: Int64(model.sizeBytes)
        )
        task.taskDescription = encodeTaskDescription(context)
        taskContexts[task.taskIdentifier] = context
        try savePendingDownload(model: model)
        task.resume()
        Log.download.info("Download task \(task.taskIdentifier) started for \(model.id)")
    }

    @MainActor
    internal func prepareSnapshotDownload(
        model: DownloadableModel,
        files: [ModelDownloadFile],
        stagingDirectory: URL
    ) {
        let metadataFiles = files.map { SnapshotFileMetadata(relativePath: $0.relativePath, sizeBytes: $0.sizeBytes) }
        snapshotDownloads[model.id] = SnapshotDownloadContext(
            stagingDirectory: stagingDirectory,
            files: Dictionary(uniqueKeysWithValues: metadataFiles.map { ($0.relativePath, $0) }),
            totalBytes: Int64(model.sizeBytes),
            progressByFile: Dictionary(uniqueKeysWithValues: metadataFiles.map {
                ($0.relativePath, SnapshotProgress(bytesDownloaded: 0, expectedBytes: Int64($0.sizeBytes)))
            }),
            completedFiles: [],
            taskIDs: []
        )
    }

    @MainActor
    private func startSnapshotDownload(model: DownloadableModel, files: [ModelDownloadFile]) throws {
        let stagingDirectory = try makeSnapshotStagingDirectory()
        prepareSnapshotDownload(model: model, files: files, stagingDirectory: stagingDirectory)
        guard var context = snapshotDownloads[model.id] else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Failed to create MLX snapshot context")
        }

        // Create all tasks and register context before persisting and resuming,
        // so reconnect metadata is written before any task can complete.
        var tasks: [(URLSessionDownloadTask, TaskContext)] = []
        for file in files {
            let task = backgroundSession.downloadTask(with: file.url)
            let taskContext = TaskContext(
                modelID: model.id,
                relativePath: file.relativePath,
                expectedBytes: Int64(file.sizeBytes)
            )
            task.taskDescription = encodeTaskDescription(taskContext)
            taskContexts[task.taskIdentifier] = taskContext
            context.taskIDs.insert(task.taskIdentifier)
            tasks.append((task, taskContext))
        }

        snapshotDownloads[model.id] = context
        // Persist before resuming so reconnect metadata is always in place.
        try savePendingDownload(
            model: model,
            snapshotFiles: files.map { SnapshotFileMetadata(relativePath: $0.relativePath, sizeBytes: $0.sizeBytes) },
            stagingDirectoryName: stagingDirectory.lastPathComponent
        )
        for (task, _) in tasks {
            task.resume()
        }
    }

    private func makeSnapshotStagingDirectory() throws -> URL {
        let url = storageService.modelsDirectory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func encodeTaskDescription(_ context: TaskContext) -> String {
        do {
            let data = try JSONEncoder().encode(context)
            guard let string = String(data: data, encoding: .utf8) else {
                Log.download.error("Failed to encode task description for \(context.modelID)")
                return context.modelID
            }
            return string
        } catch {
            Log.download.error("Failed to encode task description for \(context.modelID): \(error.localizedDescription)")
            return context.modelID
        }
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    internal func taskContext(for taskID: Int, taskDescription: String?) -> TaskContext? {
        if let context = taskContexts[taskID] {
            return context
        }
        guard let taskDescription else { return nil }
        let trimmed = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON-encoded TaskContext (new format) — detect by braces and decode strictly.
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            guard let data = taskDescription.data(using: .utf8) else {
                Log.download.error("Failed to UTF-8 encode task description for task \(taskID)")
                return nil
            }
            do {
                return try JSONDecoder().decode(TaskContext.self, from: data)
            } catch {
                Log.download.error("Failed to decode task description for task \(taskID): \(error.localizedDescription)")
                return nil
            }
        }
        // Legacy plain model-ID format (pre-JSON task descriptions).
        return TaskContext(modelID: taskDescription, relativePath: nil, expectedBytes: 0)
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    @MainActor
    internal func removeTaskTracking(taskID: Int, modelID: String) {
        taskContexts.removeValue(forKey: taskID)
        guard var snapshot = snapshotDownloads[modelID] else { return }
        snapshot.taskIDs.remove(taskID)
        // When all tasks have drained after a cancellation, clean up staging.
        if snapshot.isCancelling && snapshot.taskIDs.isEmpty {
            snapshotDownloads.removeValue(forKey: modelID)
            do {
                try FileManager.default.removeItem(at: snapshot.stagingDirectory)
            } catch {
                Log.download.error("Failed to remove snapshot staging directory: \(error.localizedDescription)")
            }
            return
        }
        snapshotDownloads[modelID] = snapshot
    }

    @MainActor
    internal func updateSnapshotProgress(
        modelID: String,
        relativePath: String,
        bytesDownloaded: Int64,
        totalBytesExpected: Int64
    ) {
        guard var snapshot = snapshotDownloads[modelID] else { return }
        let fallbackExpected = snapshot.files[relativePath].map { Int64($0.sizeBytes) } ?? 0
        let expectedBytes = totalBytesExpected > 0 ? totalBytesExpected : fallbackExpected
        snapshot.progressByFile[relativePath] = SnapshotProgress(
            bytesDownloaded: bytesDownloaded,
            expectedBytes: expectedBytes
        )
        snapshotDownloads[modelID] = snapshot

        let totalDownloaded = snapshot.progressByFile.values.reduce(0) { $0 + $1.bytesDownloaded }
        let totalExpected: Int64
        if snapshot.totalBytes > 0 {
            totalExpected = snapshot.totalBytes
        } else {
            totalExpected = snapshot.progressByFile.values.reduce(0) { $0 + $1.expectedBytes }
        }
        activeDownloads[modelID]?.updateProgress(
            bytesDownloaded: totalDownloaded,
            totalBytes: totalExpected
        )
    }

    @MainActor
    internal func completeSnapshotFile(
        modelID: String,
        relativePath: String,
        tempURL: URL
    ) throws {
        guard var snapshot = snapshotDownloads[modelID] else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Missing snapshot context for MLX download")
        }

        // The download was cancelled; discard the file without transitioning to .failed.
        // Staging cleanup happens in removeTaskTracking once all tasks have drained.
        if snapshot.isCancelling {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // Validate that the resolved destination stays within the staging directory to
        // prevent path-traversal attacks via crafted relative paths from remote metadata.
        let destination = snapshot.stagingDirectory.appendingPathComponent(relativePath)
        let resolvedDestination = destination.standardized
        let resolvedStaging = snapshot.stagingDirectory.standardized
        guard resolvedDestination.path.hasPrefix(resolvedStaging.path + "/") else {
            try? FileManager.default.removeItem(at: tempURL)
            throw HuggingFaceError.invalidDownloadedFile(reason: "Snapshot file path escapes staging directory: \(relativePath)")
        }
        try FileManager.default.createDirectory(
            at: resolvedDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: resolvedDestination.path) {
            try FileManager.default.removeItem(at: resolvedDestination)
        }
        try FileManager.default.moveItem(at: tempURL, to: resolvedDestination)

        let fileSize = (try FileManager.default.attributesOfItem(atPath: resolvedDestination.path)[.size] as? NSNumber)?.int64Value ?? snapshot.progressByFile[relativePath]?.expectedBytes ?? 0
        snapshot.completedFiles.insert(relativePath)
        snapshot.progressByFile[relativePath] = SnapshotProgress(
            bytesDownloaded: fileSize,
            expectedBytes: snapshot.progressByFile[relativePath]?.expectedBytes ?? fileSize
        )
        snapshotDownloads[modelID] = snapshot

        let totalDownloaded = snapshot.progressByFile.values.reduce(0) { $0 + $1.bytesDownloaded }
        let totalExpected = snapshot.totalBytes > 0
            ? snapshot.totalBytes
            : snapshot.progressByFile.values.reduce(0) { $0 + $1.expectedBytes }
        activeDownloads[modelID]?.updateProgress(
            bytesDownloaded: totalDownloaded,
            totalBytes: totalExpected
        )

        guard snapshot.completedFiles.count == snapshot.files.count else { return }

        try validateDownloadedFile(at: snapshot.stagingDirectory, modelType: .mlx)
        let finalFileName = activeDownloads[modelID]?.model.fileName ?? snapshot.stagingDirectory.lastPathComponent
        let finalURL = storageService.modelsDirectory.appendingPathComponent(finalFileName)
        let resolvedFinalURL = finalURL.standardized
        let resolvedModelsDir = storageService.modelsDirectory.standardized
        guard resolvedFinalURL.path.hasPrefix(resolvedModelsDir.path + "/") else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Model filename escapes models directory: \(finalFileName)")
        }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: snapshot.stagingDirectory, to: finalURL)
        activeDownloads[modelID]?.markCompleted(localURL: finalURL)
        removePendingDownload(id: modelID)
        snapshotDownloads.removeValue(forKey: modelID)
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    @MainActor
    internal func failSnapshotDownload(modelID: String, error: String, cancelRemainingTasks: Bool) {
        guard let snapshot = snapshotDownloads[modelID] else {
            if case .failed = activeDownloads[modelID]?.status {
                return
            }
            activeDownloads[modelID]?.markFailed(error: error)
            removePendingDownload(id: modelID)
            return
        }

        // When cancellation is in progress, don't overwrite .cancelled with .failed.
        // Staging cleanup is deferred to removeTaskTracking once all tasks have drained.
        if snapshot.isCancelling { return }

        if cancelRemainingTasks {
            let activeTaskIDs = snapshot.taskIDs
            backgroundSession.getAllTasks { tasks in
                for task in tasks where activeTaskIDs.contains(task.taskIdentifier) {
                    task.cancel()
                }
            }
        }

        activeDownloads[modelID]?.markFailed(error: error)
        removePendingDownload(id: modelID)
        snapshotDownloads.removeValue(forKey: modelID)
        do {
            try FileManager.default.removeItem(at: snapshot.stagingDirectory)
        } catch {
            Log.download.error("Failed to remove snapshot staging directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence (Resume Data)

    /// Persists resume data to a binary file in the caches directory so it survives app restarts.
    ///
    /// Large partial-download blobs are kept out of UserDefaults to avoid bloating
    /// the app's plist and delaying app launch.
    ///
    /// Called by the delegate when a non-cancelled single-file download fails.
    internal func persistResumeData(_ data: Data, for id: String) {
        do {
            try ensurePersistenceDirectory()
            try data.write(to: resumeDataFileURL(for: id), options: .atomic)
            Log.download.info("Persisted \(data.count) bytes of resume data for \(id)")
        } catch {
            Log.download.error("Failed to persist resume data for \(id): \(error.localizedDescription)")
        }
    }

    /// Reads and removes the resume-data file (one-shot consumption).
    ///
    /// Removing immediately prevents stale data from being used on a subsequent failure.
    @MainActor internal func consumeResumeData(for id: String) -> Data? {
        let url = resumeDataFileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    // MARK: - Persistence (Pending Downloads)

    /// Loads the pending-downloads JSON from disk, returning nil if the file is absent or unreadable.
    private func loadPendingMetadata() -> [String: [String: String]]? {
        guard let data = try? Data(contentsOf: pendingMetadataFileURL) else { return nil }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    /// Writes the pending-downloads dictionary atomically (write to temp file, then rename).
    ///
    /// Atomic rename means a crash between the write and the rename leaves the old file intact —
    /// the partial write is never visible to a subsequent read.
    private func writePendingMetadata(_ pending: [String: [String: String]]) throws {
        try ensurePersistenceDirectory()
        let data = try JSONEncoder().encode(pending)
        let tempURL = pendingMetadataFileURL.deletingLastPathComponent()
            .appendingPathComponent("pending-downloads-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        // Replace the target atomically; removeItem+move is the portable approach on Darwin.
        if FileManager.default.fileExists(atPath: pendingMetadataFileURL.path) {
            _ = try? FileManager.default.removeItem(at: pendingMetadataFileURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: pendingMetadataFileURL)
    }

    private func savePendingDownload(
        model: DownloadableModel,
        snapshotFiles: [SnapshotFileMetadata] = [],
        stagingDirectoryName: String? = nil
    ) throws {
        var pending = loadPendingMetadata() ?? [:]
        var entry = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": model.modelType == .gguf ? "gguf" : "mlx",
            "sizeBytes": String(model.sizeBytes),
        ]
        if !snapshotFiles.isEmpty {
            let data = try JSONEncoder().encode(snapshotFiles)
            guard let json = String(data: data, encoding: .utf8) else {
                throw HuggingFaceError.invalidDownloadedFile(reason: "Failed to encode pending snapshot metadata")
            }
            entry["snapshotFiles"] = json
        }
        if let stagingDirectoryName {
            entry["stagingDirectoryName"] = stagingDirectoryName
        }
        pending[model.id] = entry
        try writePendingMetadata(pending)
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    internal func removePendingDownload(id: String) {
        var pending = loadPendingMetadata() ?? [:]
        pending.removeValue(forKey: id)
        do {
            try writePendingMetadata(pending)
        } catch {
            Log.download.error("Failed to remove pending download for \(id): \(error.localizedDescription)")
        }
        // Remove the resume-data file for this ID now that the download is done.
        try? FileManager.default.removeItem(at: resumeDataFileURL(for: id))
    }

    @MainActor private func restorePendingDownloads() {
        migrateFromUserDefaults()

        guard let pending = loadPendingMetadata() else { return }

        // Collect all known IDs so we can delete orphaned resume-data files below.
        let knownIDs = Set(pending.keys)
        deleteOrphanedResumeDataFiles(knownIDs: knownIDs)

        for (id, info) in pending {
            // Only restore if we don't already have a state for this download.
            guard activeDownloads[id] == nil else { continue }
            guard let repoID = info["repoID"],
                  let fileName = info["fileName"],
                  let displayName = info["displayName"],
                  let typeStr = info["modelType"] else { continue }

            let modelType: ModelType = typeStr == "gguf" ? .gguf : .mlx
            let model = DownloadableModel(
                repoID: repoID,
                fileName: fileName,
                displayName: displayName,
                modelType: modelType,
                sizeBytes: UInt64(info["sizeBytes"] ?? "") ?? 0
            )
            let state = DownloadState(model: model)
            activeDownloads[id] = state
            if modelType == .mlx,
               let stagingDirectoryName = info["stagingDirectoryName"],
               let snapshotJSON = info["snapshotFiles"],
               let snapshotData = snapshotJSON.data(using: .utf8) {
                do {
                    let files = try JSONDecoder().decode([SnapshotFileMetadata].self, from: snapshotData)
                    snapshotDownloads[id] = SnapshotDownloadContext(
                        stagingDirectory: storageService.modelsDirectory.appendingPathComponent(
                            stagingDirectoryName,
                            isDirectory: true
                        ),
                        files: Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) }),
                        totalBytes: Int64(model.sizeBytes),
                        progressByFile: Dictionary(uniqueKeysWithValues: files.map {
                            ($0.relativePath, SnapshotProgress(
                                bytesDownloaded: 0,
                                expectedBytes: Int64($0.sizeBytes)
                            ))
                        }),
                        completedFiles: [],
                        taskIDs: []
                    )
                } catch {
                    Log.download.error("Failed to restore snapshot metadata for \(id): \(error.localizedDescription)")
                }
            }
            Log.download.info("Restored pending download state for \(id)")
        }
    }

    // MARK: - Cleanup Sweep

    /// Deletes resume-data files for download IDs not present in the current pending-metadata
    /// list. These orphans accumulate when a download crashes without the normal teardown path.
    private func deleteOrphanedResumeDataFiles(knownIDs: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: persistenceDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for fileURL in contents where fileURL.lastPathComponent.hasPrefix("resume-") && fileURL.pathExtension == "bin" {
            let filename = fileURL.deletingPathExtension().lastPathComponent   // "resume-<encoded-id>"
            let encodedID = String(filename.dropFirst("resume-".count))
            let decodedID = encodedID.removingPercentEncoding ?? encodedID
            if !knownIDs.contains(decodedID) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    Log.download.info("Removed orphaned resume-data file: \(fileURL.lastPathComponent)")
                } catch {
                    Log.download.error("Failed to remove orphaned resume-data file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - One-time UserDefaults Migration

    /// Migrates resume data and pending-download metadata from the legacy UserDefaults
    /// storage to the new file-based persistence, then deletes the old keys.
    ///
    /// Runs once on first launch after the upgrade. Subsequent launches skip it because
    /// the old keys are no longer present.
    private func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        let pendingKey = BaseChatConfiguration.shared.pendingDownloadsKey

        // Migrate pending metadata — only when the new file doesn't already exist.
        if !FileManager.default.fileExists(atPath: pendingMetadataFileURL.path),
           let legacy = defaults.dictionary(forKey: pendingKey) as? [String: [String: String]],
           !legacy.isEmpty {
            do {
                try writePendingMetadata(legacy)
                Log.download.info("Migrated \(legacy.count) pending-download(s) from UserDefaults to file")
            } catch {
                Log.download.error("Failed to migrate pending downloads from UserDefaults: \(error.localizedDescription)")
            }
        }
        defaults.removeObject(forKey: pendingKey)

        // Migrate any resume-data blobs stored under the legacy "resumeData.<id>" keys.
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("resumeData.") {
            let id = String(key.dropFirst("resumeData.".count))
            if let data = defaults.data(forKey: key) {
                do {
                    try ensurePersistenceDirectory()
                    try data.write(to: resumeDataFileURL(for: id), options: .atomic)
                    Log.download.info("Migrated resume data for \(id) from UserDefaults to file")
                } catch {
                    Log.download.error("Failed to migrate resume data for \(id): \(error.localizedDescription)")
                }
            }
            defaults.removeObject(forKey: key)
        }
    }
}

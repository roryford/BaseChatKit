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
public final class BackgroundDownloadManager: NSObject {

    // MARK: - Constants

    /// The background URL session identifier (derived from BaseChatConfiguration).
    public static var sessionIdentifier: String {
        BaseChatConfiguration.shared.downloadSessionIdentifier
    }

    /// Minimum free disk space buffer beyond the model size (500 MB).
    private static let diskSpaceBuffer: UInt64 = 500_000_000

    /// GGUF magic bytes: "GGUF" in ASCII (0x47, 0x47, 0x55, 0x46).
    private static let ggufMagic: [UInt8] = [0x47, 0x47, 0x55, 0x46]

    // MARK: - Observable State

    /// Active and recently completed downloads, keyed by `DownloadableModel.id`.
    ///
    /// Setter is `internal` (not `private`) so tests can inject state via `@testable import`.
    public internal(set) var activeDownloads: [String: DownloadState] = [:]

    /// Whether any download is currently in progress.
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

    /// Maps `URLSessionTask.taskIdentifier` to `DownloadableModel.id` for delegate routing.
    private var downloadTaskMap: [Int: String] = [:]

    /// The storage service used to determine where to place completed files.
    private let storageService: ModelStorageService

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

    /// Persists download metadata so we can reconnect after app restart.
    private let defaults = UserDefaults.standard
    private var pendingDownloadsKey: String {
        BaseChatConfiguration.shared.pendingDownloadsKey
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
        Log.download.info("Starting download for \(model.displayName) from \(downloadURL)")

        // Check disk space.
        try await checkDiskSpace(requiredBytes: model.sizeBytes)

        // Ensure the models directory exists.
        try storageService.ensureModelsDirectory()

        // Create the download state.
        let state = DownloadState(model: model)

        // Create and start the URLSession download task.
        let task = backgroundSession.downloadTask(with: downloadURL)
        task.taskDescription = model.id

        // Track the mapping.
        downloadTaskMap[task.taskIdentifier] = model.id
        activeDownloads[model.id] = state

        // Persist pending download info for reconnection.
        savePendingDownload(model: model)

        task.resume()
        Log.download.info("Download task \(task.taskIdentifier) started for \(model.id)")

        return state
    }

    /// Cancels an in-progress download.
    ///
    /// - Parameter id: The `DownloadableModel.id` of the download to cancel.
    @MainActor public func cancelDownload(id: String) {
        Log.download.info("Cancelling download: \(id)")

        // Find and cancel the URLSession task.
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where task.taskDescription == id {
                task.cancel()
            }

            Task { @MainActor in
                self.activeDownloads[id]?.markCancelled()
                self.removePendingDownload(id: id)
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
    /// - Parameters:
    ///   - fileURL: The temporary file location from URLSession.
    ///   - modelType: The expected model type.
    /// - Throws: `HuggingFaceError.invalidDownloadedFile` if validation fails.
    public func validateDownloadedFile(at fileURL: URL, modelType: ModelType) throws {
        switch modelType {
        case .gguf:
            try validateGGUFFile(at: fileURL)
        case .mlx:
            // For individual MLX file downloads, check the file exists.
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw HuggingFaceError.invalidDownloadedFile(reason: "Downloaded MLX file does not exist")
            }
            // If this is a directory (assembled MLX repo), verify config.json and at least one .safetensors file.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let configPath = fileURL.appendingPathComponent("config.json").path
                guard FileManager.default.fileExists(atPath: configPath) else {
                    throw HuggingFaceError.invalidDownloadedFile(reason: "MLX model directory is missing config.json")
                }
                let contents = try FileManager.default.contentsOfDirectory(atPath: fileURL.path)
                guard contents.contains(where: { $0.hasSuffix(".safetensors") }) else {
                    throw HuggingFaceError.invalidDownloadedFile(reason: "MLX model directory contains no .safetensors files")
                }
            }
        case .foundation:
            throw HuggingFaceError.invalidDownloadedFile(reason: "Foundation models cannot be downloaded")
        }
    }

    /// Validates that a file begins with the GGUF magic bytes.
    private func validateGGUFFile(at fileURL: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Cannot open downloaded GGUF file")
        }
        defer { handle.closeFile() }

        guard let headerData = try? handle.read(upToCount: 4), headerData.count == 4 else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "GGUF file too small — expected at least 4 bytes"
            )
        }

        let bytes = [UInt8](headerData)
        guard bytes == Self.ggufMagic else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Invalid GGUF magic bytes: expected [47,47,55,46], got \(bytes)"
            )
        }

        // Verify file size is reasonable — a truncated file with correct magic would pass above.
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? UInt64) ?? 0
        guard fileSize > 1_000_000 else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Downloaded file is too small (\(fileSize) bytes) — likely corrupted or incomplete"
            )
        }

        Log.download.debug("GGUF file validated successfully at \(fileURL.lastPathComponent)")
    }

    // MARK: - Persistence (Pending Downloads)

    private func savePendingDownload(model: DownloadableModel) {
        var pending = defaults.dictionary(forKey: pendingDownloadsKey) as? [String: [String: String]] ?? [:]
        pending[model.id] = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": model.modelType == .gguf ? "gguf" : "mlx"
        ]
        defaults.set(pending, forKey: pendingDownloadsKey)
    }

    private func removePendingDownload(id: String) {
        var pending = defaults.dictionary(forKey: pendingDownloadsKey) as? [String: [String: String]] ?? [:]
        pending.removeValue(forKey: id)
        defaults.set(pending, forKey: pendingDownloadsKey)
    }

    @MainActor private func restorePendingDownloads() {
        guard let pending = defaults.dictionary(forKey: pendingDownloadsKey) as? [String: [String: String]] else {
            return
        }

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
                sizeBytes: 0  // Unknown after restart; progress will update it.
            )
            let state = DownloadState(model: model)
            activeDownloads[id] = state
            Log.download.info("Restored pending download state for \(id)")
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadManager: URLSessionDownloadDelegate {

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        let taskDescription = downloadTask.taskDescription

        Task { @MainActor [weak self] in
            guard let modelID = self?.downloadTaskMap[taskID] ?? taskDescription else { return }
            self?.activeDownloads[modelID]?.updateProgress(
                bytesDownloaded: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let taskDescription = downloadTask.taskDescription

        // Copy the file to a safe temporary location before this method returns,
        // since the system deletes the file at `location` immediately after.
        let tempURL: URL
        do {
            let tempDir = FileManager.default.temporaryDirectory
            tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".download")
            try FileManager.default.moveItem(at: location, to: tempURL)
        } catch {
            Log.download.error("Failed to preserve downloaded file: \(error.localizedDescription)")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            guard let modelID = self.downloadTaskMap[taskID] ?? taskDescription else {
                Log.download.error("Completed download has no model ID mapping (task \(taskID))")
                return
            }

            guard let state = self.activeDownloads[modelID] else {
                Log.download.error("No DownloadState for completed download: \(modelID)")
                return
            }

            let model = state.model

            do {
                // Validate the downloaded file.
                try self.validateDownloadedFile(at: tempURL, modelType: model.modelType)

                // Move to the models directory.
                let destination = self.storageService.modelsDirectory.appendingPathComponent(model.fileName)

                // Remove any existing file at the destination.
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                try FileManager.default.moveItem(at: tempURL, to: destination)
                Log.download.info("Download complete: \(model.displayName) → \(destination.lastPathComponent)")

                self.activeDownloads[modelID]?.markCompleted(localURL: destination)
                self.removePendingDownload(id: modelID)
                self.downloadTaskMap.removeValue(forKey: taskID)
            } catch {
                Log.download.error("Post-download processing failed for \(modelID): \(error.localizedDescription)")
                self.activeDownloads[modelID]?.markFailed(error: error.localizedDescription)
                self.removePendingDownload(id: modelID)
                self.downloadTaskMap.removeValue(forKey: taskID)
                // Clean up temp file on failure.
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }  // No error means success; handled in didFinishDownloadingTo.

        let taskID = task.taskIdentifier
        let taskDescription = task.taskDescription
        let nsError = error as NSError
        let errorDesc = error.localizedDescription

        Task { @MainActor [weak self] in
            guard let self else { return }
            let modelID = self.downloadTaskMap[taskID] ?? taskDescription ?? "unknown"
            Log.download.error("Download failed for \(modelID): \(errorDesc)")

            // Don't report cancellation as a failure.
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                self.activeDownloads[modelID]?.markCancelled()
            } else {
                self.activeDownloads[modelID]?.markFailed(error: errorDesc)
            }
            self.removePendingDownload(id: modelID)
            self.downloadTaskMap.removeValue(forKey: taskID)
        }
    }
}

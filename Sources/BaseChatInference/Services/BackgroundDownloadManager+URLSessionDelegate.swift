import Foundation
import os

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
            guard let self,
                  let context = self.taskContext(for: taskID, taskDescription: taskDescription) else { return }
            if let relativePath = context.relativePath {
                self.updateSnapshotProgress(
                    modelID: context.modelID,
                    relativePath: relativePath,
                    bytesDownloaded: totalBytesWritten,
                    totalBytesExpected: totalBytesExpectedToWrite
                )
            } else {
                self.activeDownloads[context.modelID]?.updateProgress(
                    bytesDownloaded: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite
                )
            }
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

            guard let context = self.taskContext(for: taskID, taskDescription: taskDescription) else {
                Log.download.error("Completed download has no model ID mapping (task \(taskID))")
                return
            }

            guard let state = self.activeDownloads[context.modelID] else {
                Log.download.error("No DownloadState for completed download: \(context.modelID)")
                return
            }

            let model = state.model

            do {
                if let relativePath = context.relativePath {
                    try self.completeSnapshotFile(
                        modelID: context.modelID,
                        relativePath: relativePath,
                        tempURL: tempURL
                    )
                } else {
                    try self.validateDownloadedFile(at: tempURL, modelType: model.modelType)
                    let destination = self.storageService.modelsDirectory.appendingPathComponent(model.fileName)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }

                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    Log.download.info("Download complete: \(model.displayName) → \(destination.lastPathComponent)")

                    self.activeDownloads[context.modelID]?.markCompleted(localURL: destination)
                    self.removePendingDownload(id: context.modelID)
                }
                self.removeTaskTracking(taskID: taskID, modelID: context.modelID)
            } catch {
                Log.download.error("Post-download processing failed for \(context.modelID): \(error.localizedDescription)")
                if context.relativePath != nil {
                    self.failSnapshotDownload(
                        modelID: context.modelID,
                        error: error.localizedDescription,
                        cancelRemainingTasks: true
                    )
                } else {
                    self.activeDownloads[context.modelID]?.markFailed(error: error.localizedDescription)
                    self.removePendingDownload(id: context.modelID)
                }
                self.removeTaskTracking(taskID: taskID, modelID: context.modelID)
                do {
                    try FileManager.default.removeItem(at: tempURL)
                } catch {
                    Log.download.error("Failed to remove temp download \(tempURL.lastPathComponent): \(error.localizedDescription)")
                }
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
            guard let context = self.taskContext(for: taskID, taskDescription: taskDescription) else { return }
            Log.download.error("Download failed for \(context.modelID): \(errorDesc)")

            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                if context.relativePath != nil {
                    if case .failed = self.activeDownloads[context.modelID]?.status {
                        self.removeTaskTracking(taskID: taskID, modelID: context.modelID)
                        return
                    }
                }
                self.activeDownloads[context.modelID]?.markCancelled()
            } else {
                if context.relativePath != nil {
                    self.failSnapshotDownload(
                        modelID: context.modelID,
                        error: errorDesc,
                        cancelRemainingTasks: true
                    )
                } else {
                    self.activeDownloads[context.modelID]?.markFailed(error: errorDesc)
                }
            }
            self.removePendingDownload(id: context.modelID)
            self.removeTaskTracking(taskID: taskID, modelID: context.modelID)
        }
    }
}

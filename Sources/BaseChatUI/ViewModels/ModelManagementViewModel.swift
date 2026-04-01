import Foundation
import Observation
import BaseChatCore

public enum ModelImportError: LocalizedError, Equatable {
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported model format. Import a .gguf file or an MLX model folder containing config.json."
        }
    }
}

/// View model for the model browser and storage management sheets.
///
/// Coordinates HuggingFace search, curated recommendations, downloads, and
/// local model deletion. Injected into the view hierarchy via `@Environment`.
@Observable
@MainActor
public final class ModelManagementViewModel {

    // MARK: - Search State

    /// The current search query bound to the search field.
    public var searchQuery: String = ""

    /// Models returned from HuggingFace search.
    public private(set) var searchResults: [DownloadableModel] = []

    /// Curated models filtered to this device's recommended tier.
    public private(set) var recommendedModels: [DownloadableModel] = []

    /// Whether a search request is in flight.
    public private(set) var isSearching: Bool = false

    /// User-facing error from the last search or download attempt.
    public var searchError: String?

    // MARK: - Services

    private let huggingFaceService: (any HuggingFaceServiceProtocol)?
    private let downloadManager: BackgroundDownloadManager?
    private let deviceCapability: DeviceCapabilityService
    private let modelStorage: ModelStorageService

    // MARK: - Download Tracking

    /// Mirrors `downloadManager.activeDownloads` as a stored property so that
    /// SwiftUI observation tracking works correctly. Computed properties that
    /// read from a nested `@Observable` object do not propagate change
    /// notifications to views observing this view model.
    public private(set) var trackedDownloads: [String: DownloadState] = [:]

    /// Polling task that syncs download state from the manager to this view model.
    private var downloadSyncTask: Task<Void, Never>?

    // MARK: - Private State

    private var searchTask: Task<Void, Never>?

    /// Cached set of file names from `discoverModels()` to avoid N+1 filesystem scans.
    private var discoveredModelFileNames: Set<String>?

    // MARK: - Initialisation

    public init(
        huggingFaceService: (any HuggingFaceServiceProtocol)? = nil,
        downloadManager: BackgroundDownloadManager? = nil,
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService()
    ) {
        self.huggingFaceService = huggingFaceService
        self.downloadManager = downloadManager
        self.deviceCapability = deviceCapability
        self.modelStorage = modelStorage
    }

    /// Creates a production-ready model manager with search and downloads enabled.
    public static func live(
        huggingFaceService: any HuggingFaceServiceProtocol = HuggingFaceService(),
        downloadManager: BackgroundDownloadManager = BackgroundDownloadManager(),
        deviceCapability: DeviceCapabilityService = DeviceCapabilityService(),
        modelStorage: ModelStorageService = ModelStorageService()
    ) -> ModelManagementViewModel {
        downloadManager.reconnectBackgroundSession()
        return ModelManagementViewModel(
            huggingFaceService: huggingFaceService,
            downloadManager: downloadManager,
            deviceCapability: deviceCapability,
            modelStorage: modelStorage
        )
    }

    // MARK: - Computed Properties

    /// The recommended model size tier for this device.
    public var recommendation: ModelSizeRecommendation {
        deviceCapability.recommendedModelSize()
    }

    /// Human-readable total storage used by downloaded models.
    public var totalStorageUsed: String {
        modelStorage.storageUsedFormatted
    }

    /// All currently active downloads, keyed by model ID.
    public var activeDownloads: [String: DownloadState] {
        trackedDownloads
    }

    /// Whether any downloads are in progress.
    public var hasActiveDownloads: Bool {
        trackedDownloads.values.contains { state in
            switch state.status {
            case .queued, .downloading:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
    }

    /// Number of downloads that have reached the `.completed` state.
    ///
    /// The app can observe this via `onChange` to trigger a model-list refresh
    /// whenever a new download finishes, so the sidebar picker updates without
    /// requiring an app restart.
    public var completedDownloadCount: Int {
        trackedDownloads.values.filter {
            if case .completed = $0.status { return true }
            return false
        }.count
    }

    /// Path to the models directory on disk.
    public var modelsDirectoryPath: String {
        modelStorage.modelsDirectory.path
    }

    /// Models currently on disk.
    public var discoveredModels: [ModelInfo] {
        modelStorage.discoverModels()
    }

    // MARK: - Recommendations

    /// Loads curated model recommendations for this device's capability tier.
    public func loadRecommendations() {
        guard let service = huggingFaceService else {
            // No service wired yet — fall back to showing curated models directly.
            recommendedModels = CuratedModel.all
                .filter { $0.recommendedFor.contains(recommendation) }
                .map { DownloadableModel(from: $0) }
            return
        }

        recommendedModels = service.curatedModels(for: recommendation)
    }

    // MARK: - Search

    /// Searches HuggingFace for models matching `searchQuery`.
    ///
    /// Debounces by 500ms so rapid typing doesn't fire excessive requests.
    public func search() async {
        // Cancel any in-flight search.
        searchTask?.cancel()

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }

        guard let service = huggingFaceService else {
            searchError = "Model search is not available yet. Download services are being configured."
            return
        }

        searchError = nil
        isSearching = true

        let task = Task {
            // Debounce: wait 500ms before actually searching.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            do {
                let results = try await service.searchModels(query: query)
                guard !Task.isCancelled else { return }
                searchResults = results
                Log.network.info("Search returned \(results.count) results for '\(query, privacy: .private)'")
            } catch {
                guard !Task.isCancelled else { return }
                searchError = "Search failed: \(error.localizedDescription)"
                Log.network.error("Search error: \(error)")
            }

            guard !Task.isCancelled else { return }
            isSearching = false
        }

        searchTask = task
        await task.value
    }

    // MARK: - Downloads

    /// Starts downloading a model from HuggingFace.
    public func startDownload(_ model: DownloadableModel) {
        guard let service = huggingFaceService else {
            searchError = "Download services are not available yet."
            return
        }

        guard let manager = downloadManager else {
            searchError = "Download manager is not available yet."
            return
        }

        let url = service.downloadURL(for: model)

        Task {
            do {
                let state = try await manager.startDownload(model, downloadURL: url)
                trackedDownloads[model.id] = state
                Log.download.info("Started download: \(model.displayName), id=\(state.id)")
                startDownloadSync()
            } catch {
                searchError = "Failed to start download: \(error.localizedDescription)"
                Log.download.error("Download start error: \(error)")
            }
        }
    }

    /// Polls the download manager for state changes and syncs to `trackedDownloads`.
    ///
    /// This bridges the gap between the `BackgroundDownloadManager` (which updates
    /// via URLSession delegate callbacks) and this view model's stored properties
    /// (which SwiftUI observes for re-rendering).
    private func startDownloadSync() {
        guard downloadSyncTask == nil else { return }

        downloadSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let manager = self.downloadManager else { break }

                // Sync all state from the manager.
                let managerDownloads = manager.activeDownloads
                for (id, state) in managerDownloads {
                    self.trackedDownloads[id] = state
                }

                // Stop polling if no active downloads remain.
                let hasActive = managerDownloads.values.contains { state in
                    switch state.status {
                    case .queued, .downloading: return true
                    default: return false
                    }
                }

                if !hasActive && !managerDownloads.isEmpty {
                    // Final sync then stop.
                    break
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.downloadSyncTask = nil
        }
    }

    /// Cancels an active download.
    public func cancelDownload(id: String) {
        downloadManager?.cancelDownload(id: id)
        Log.download.info("Cancelled download: \(id)")
    }

    // MARK: - Local Model Management

    /// Deletes a downloaded model from disk.
    public func deleteModel(_ model: ModelInfo) throws {
        try modelStorage.deleteModel(model)
        Log.download.info("Deleted model: \(model.name)")
    }

    /// Imports a local model file or directory into the app's models directory.
    @discardableResult
    public func importModel(from sourceURL: URL) throws -> ModelInfo {
        let destination = try modelStorage.importModel(from: sourceURL)

        if let imported = importedModel(at: destination) {
            invalidateModelCache()
            return imported
        }

        try? FileManager.default.removeItem(at: destination)
        throw ModelImportError.unsupportedFormat
    }

    // MARK: - Device Capability Queries

    /// Whether this device has enough RAM to run a model of the given size.
    public func canRunModel(sizeBytes: UInt64) -> Bool {
        deviceCapability.canLoadModel(estimatedMemoryBytes: sizeBytes)
    }

    /// Whether a downloadable model's file already exists on disk.
    ///
    /// Uses a cached snapshot of discovered models to avoid repeated filesystem scans.
    /// Call `invalidateModelCache()` after downloads complete or models are deleted.
    public func isModelDownloaded(_ model: DownloadableModel) -> Bool {
        if discoveredModelFileNames == nil {
            discoveredModelFileNames = Set(modelStorage.discoverModels().map(\.fileName))
        }
        return discoveredModelFileNames?.contains(model.fileName) ?? false
    }

    /// Invalidates the cached model discovery results, forcing a fresh filesystem scan
    /// on the next `isModelDownloaded` call.
    public func invalidateModelCache() {
        discoveredModelFileNames = nil
    }

    /// Returns the active download state for a model, if any.
    public func downloadState(for model: DownloadableModel) -> DownloadState? {
        activeDownloads[model.id]
    }

    private func importedModel(at url: URL) -> ModelInfo? {
        if let gguf = ModelInfo(ggufURL: url) {
            return gguf
        }

        if let mlx = ModelInfo(mlxDirectory: url) {
            return mlx
        }

        return nil
    }
}

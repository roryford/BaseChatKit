import Foundation
import Observation
import BaseChatCore

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
        downloadManager?.activeDownloads ?? [:]
    }

    /// Whether any downloads are in progress.
    public var hasActiveDownloads: Bool {
        downloadManager?.hasActiveDownloads ?? false
    }

    /// Number of downloads that have reached the `.completed` state.
    ///
    /// The app can observe this via `onChange` to trigger a model-list refresh
    /// whenever a new download finishes, so the sidebar picker updates without
    /// requiring an app restart.
    public var completedDownloadCount: Int {
        activeDownloads.values.filter {
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
                Log.download.info("Started download: \(model.displayName), id=\(state.id)")
            } catch {
                searchError = "Failed to start download: \(error.localizedDescription)"
                Log.download.error("Download start error: \(error)")
            }
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
}

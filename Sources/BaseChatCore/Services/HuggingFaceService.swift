import Foundation
import HuggingFace
import os

// MARK: - Protocol

/// Provides HuggingFace Hub API operations (search, model info, URL construction).
///
/// Does **not** handle downloads — that is `BackgroundDownloadManager`'s job.
/// Conforming types must be `Sendable` so they can be shared across actors.
public protocol HuggingFaceServiceProtocol: Sendable {
    /// Searches HuggingFace for text-generation models matching the query.
    ///
    /// Results include one `DownloadableModel` per downloadable file (each GGUF
    /// quant variant is a separate row; MLX repos produce a single row).
    func searchModels(query: String) async throws -> [DownloadableModel]

    /// Returns curated models appropriate for the given device size recommendation.
    func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel]

    /// Fetches all downloadable files (GGUF + MLX) for a specific HuggingFace repo.
    func getModelFiles(repoID: String) async throws -> [DownloadableModel]

    /// Constructs the direct download URL for a model file on HuggingFace.
    func downloadURL(for model: DownloadableModel) -> URL
}

// MARK: - Implementation

/// Concrete `HuggingFaceServiceProtocol` backed by the `swift-huggingface` SDK.
public final class HuggingFaceService: HuggingFaceServiceProtocol {

    private let hubClient: HubClient

    public init(hubClient: HubClient = .default) {
        self.hubClient = hubClient
    }

    // MARK: - Search

    public func searchModels(query: String) async throws -> [DownloadableModel] {
        Log.network.info("Searching HuggingFace for: \(query, privacy: .private)")

        let response: PaginatedResponse<Model>
        do {
            response = try await hubClient.listModels(
                search: query,
                sort: "downloads",
                direction: .descending,
                limit: 20,
                full: true,
                pipelineTag: "text-generation"
            )
        } catch {
            Log.network.error("HuggingFace search failed: \(error.localizedDescription)")
            throw HuggingFaceError.searchFailed(underlying: error)
        }

        // Filter to repos that contain GGUF files (single-file downloadable).
        // MLX repos require snapshot downloads (multiple files) which is not yet supported.
        let ggufRepos = response.items.filter { model in
            guard let siblings = model.siblings else { return false }
            return siblings.contains { $0.relativeFilename.lowercased().hasSuffix(".gguf") }
        }

        // Fetch each GGUF repo with filesMetadata to get actual file sizes.
        var allModels: [DownloadableModel] = []
        await withTaskGroup(of: [DownloadableModel].self) { group in
            for model in ggufRepos {
                group.addTask {
                    do {
                        let detailed = try await self.hubClient.getModel(
                            model.id,
                            full: true,
                            filesMetadata: true
                        )
                        return self.convertModelToDownloadables(detailed)
                    } catch {
                        Log.network.warning("Failed to fetch details for \(model.id): \(error)")
                        return self.convertModelToDownloadables(model)
                    }
                }
            }
            for await models in group {
                allModels.append(contentsOf: models)
            }
        }

        Log.network.info("Search returned \(allModels.count) downloadable files from \(ggufRepos.count) repos")
        return allModels
    }

    // MARK: - Curated

    public func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel] {
        CuratedModel.all
            .filter { $0.recommendedFor.contains(recommendation) }
            .map { DownloadableModel(from: $0) }
    }

    // MARK: - Get Model Files

    public func getModelFiles(repoID: String) async throws -> [DownloadableModel] {
        Log.network.info("Fetching files for repo: \(repoID)")

        guard let repoIdentifier = Repo.ID(rawValue: repoID) else {
            throw HuggingFaceError.invalidRepoID(repoID)
        }

        let model: Model
        do {
            model = try await hubClient.getModel(
                repoIdentifier,
                full: true,
                filesMetadata: true
            )
        } catch {
            Log.network.error("Failed to fetch model \(repoID): \(error.localizedDescription)")
            throw HuggingFaceError.modelNotFound(repoID: repoID)
        }

        let downloadables = convertModelToDownloadables(model)
        Log.network.info("Found \(downloadables.count) downloadable files in \(repoID)")
        return downloadables
    }

    // MARK: - Download URL

    public func downloadURL(for model: DownloadableModel) -> URL {
        // HuggingFace direct download: https://huggingface.co/{repoID}/resolve/main/{fileName}
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(model.repoID)/resolve/main/\(model.fileName)"
        // Force unwrap is safe here: we control the components and they are always valid.
        // swiftlint:disable:next force_unwrapping
        return components.url!
    }

    // MARK: - Private Helpers

    /// Converts a HuggingFace `Model` into zero or more `DownloadableModel` entries.
    ///
    /// Currently only supports GGUF repos (one entry per `.gguf` file).
    /// MLX repos require snapshot downloads (multiple files) which is not yet implemented.
    private func convertModelToDownloadables(_ model: Model) -> [DownloadableModel] {
        guard let siblings = model.siblings else { return [] }

        let repoID = model.id.rawValue
        var results: [DownloadableModel] = []

        // Check for GGUF files.
        let ggufFiles = siblings.filter { $0.relativeFilename.lowercased().hasSuffix(".gguf") }
        for file in ggufFiles {
            let sizeBytes = UInt64(file.size ?? 0)
            let fileName = file.relativeFilename
            // Use the GGUF filename (minus extension) as display name for quant differentiation.
            let quantName = Self.cleanDisplayName(
                from: String(fileName.dropLast(5)) // strip ".gguf"
            )
            results.append(DownloadableModel(
                repoID: repoID,
                fileName: fileName,
                displayName: quantName,
                modelType: .gguf,
                sizeBytes: sizeBytes,
                downloads: model.downloads,
                isCurated: false,
                promptTemplate: nil,
                description: nil
            ))
        }

        // MLX repos (config.json + .safetensors) are not included in search results
        // because they require snapshot downloads (multiple files), which is not yet
        // supported. Users can manually import MLX models via drag-and-drop on macOS.

        return results
    }

    /// Converts a repo name like "Mistral-7B-Instruct-v0.3-GGUF" into "Mistral 7B Instruct v0.3 GGUF".
    private static func cleanDisplayName(from name: String) -> String {
        name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

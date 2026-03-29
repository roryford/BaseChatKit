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

        let models = response.items.flatMap { convertModelToDownloadables($0) }
        Log.network.info("Search returned \(models.count) downloadable files from \(response.items.count) repos")
        return models
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
                full: true
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
    /// - GGUF repos: one entry per `.gguf` file (each quant variant).
    /// - MLX repos: one entry if the repo contains `config.json` + `.safetensors` files.
    /// - Repos with neither format are skipped entirely.
    private func convertModelToDownloadables(_ model: Model) -> [DownloadableModel] {
        guard let siblings = model.siblings else { return [] }

        let repoID = model.id.rawValue
        let displayNameBase = Self.cleanDisplayName(from: model.id.name)
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

        // Check for MLX format (config.json + at least one .safetensors file).
        let hasConfig = siblings.contains { $0.relativeFilename == "config.json" }
        let hasSafetensors = siblings.contains {
            $0.relativeFilename.lowercased().hasSuffix(".safetensors")
        }
        if hasConfig && hasSafetensors && ggufFiles.isEmpty {
            // MLX repos are downloaded as a directory; use the repo name as the file name.
            let totalSize = siblings.reduce(UInt64(0)) { $0 + UInt64($1.size ?? 0) }
            results.append(DownloadableModel(
                repoID: repoID,
                fileName: model.id.name,
                displayName: displayNameBase,
                modelType: .mlx,
                sizeBytes: totalSize,
                downloads: model.downloads,
                isCurated: false,
                promptTemplate: nil,
                description: nil
            ))
        }

        return results
    }

    /// Converts a repo name like "Mistral-7B-Instruct-v0.3-GGUF" into "Mistral 7B Instruct v0.3 GGUF".
    private static func cleanDisplayName(from name: String) -> String {
        name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

import Foundation
import BaseChatCore

/// Configurable mock HuggingFace service for testing.
///
/// Shared across all test targets via the `BaseChatTestSupport` module.
public final class MockHuggingFaceService: HuggingFaceServiceProtocol {
    public var searchResults: [DownloadableModel] = []
    public var searchError: Error?
    public var modelFiles: [DownloadableModel] = []
    public var searchCallCount = 0

    public init() {}

    public func searchModels(query: String) async throws -> [DownloadableModel] {
        searchCallCount += 1
        if let error = searchError { throw error }
        return searchResults
    }

    public func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel] {
        CuratedModel.all
            .filter { $0.recommendedFor.contains(recommendation) }
            .map { DownloadableModel(from: $0) }
    }

    public func getModelFiles(repoID: String) async throws -> [DownloadableModel] {
        modelFiles
    }

    public func downloadURL(for model: DownloadableModel) -> URL {
        // Safe to force-unwrap: we control the URL components in tests.
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://huggingface.co/\(model.repoID)/resolve/main/\(model.fileName)")!
    }
}

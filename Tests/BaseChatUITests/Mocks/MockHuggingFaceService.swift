import Foundation
@testable import BaseChatUI
import BaseChatCore

final class MockHuggingFaceService: HuggingFaceServiceProtocol {
    var searchResults: [DownloadableModel] = []
    var searchError: Error?
    var modelFiles: [DownloadableModel] = []
    var searchCallCount = 0

    func searchModels(query: String) async throws -> [DownloadableModel] {
        searchCallCount += 1
        if let error = searchError { throw error }
        return searchResults
    }

    func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel] {
        CuratedModel.all
            .filter { $0.recommendedFor.contains(recommendation) }
            .map { DownloadableModel(from: $0) }
    }

    func getModelFiles(repoID: String) async throws -> [DownloadableModel] {
        modelFiles
    }

    func downloadURL(for model: DownloadableModel) -> URL {
        // Safe to force-unwrap: we control the URL components in tests.
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://huggingface.co/\(model.repoID)/resolve/main/\(model.fileName)")!
    }
}

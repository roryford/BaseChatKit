import Foundation
import BaseChatCore
import os

/// Configurable mock HuggingFace service for testing.
///
/// Shared across all test targets via the `BaseChatTestSupport` module.
public final class MockHuggingFaceService: HuggingFaceServiceProtocol {
    private struct State {
        var searchResults: [DownloadableModel] = []
        var searchError: Error?
        var modelFiles: [DownloadableModel] = []
        var searchCallCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public var searchResults: [DownloadableModel] {
        get { state.withLock { $0.searchResults } }
        set { state.withLock { $0.searchResults = newValue } }
    }

    public var searchError: Error? {
        get { state.withLock { $0.searchError } }
        set { state.withLock { $0.searchError = newValue } }
    }

    public var modelFiles: [DownloadableModel] {
        get { state.withLock { $0.modelFiles } }
        set { state.withLock { $0.modelFiles = newValue } }
    }

    public var searchCallCount: Int {
        state.withLock { $0.searchCallCount }
    }

    public init() {}

    public func searchModels(query: String) async throws -> [DownloadableModel] {
        let (error, results) = state.withLock { state in
            state.searchCallCount += 1
            return (state.searchError, state.searchResults)
        }
        if let error { throw error }
        return results
    }

    public func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel] {
        CuratedModel.all
            .filter { $0.recommendedFor.contains(recommendation) }
            .map { DownloadableModel(from: $0) }
    }

    public func getModelFiles(repoID: String) async throws -> [DownloadableModel] {
        state.withLock { $0.modelFiles }
    }

    public func downloadURL(for model: DownloadableModel) -> URL {
        // Safe to force-unwrap: we control the URL components in tests.
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://huggingface.co/\(model.repoID)/resolve/main/\(model.fileName)")!
    }
}

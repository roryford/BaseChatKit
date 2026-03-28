import XCTest
@testable import BaseChatUI
import BaseChatCore

@MainActor
final class ModelManagementViewModelTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    // MARK: - Default State

    func test_init_defaultState() {
        let vm = ModelManagementViewModel()

        XCTAssertEqual(vm.searchQuery, "", "searchQuery should be empty on init")
        XCTAssertTrue(vm.searchResults.isEmpty, "searchResults should be empty on init")
        XCTAssertFalse(vm.isSearching, "isSearching should be false on init")
        XCTAssertNil(vm.searchError, "searchError should be nil on init")
    }

    // MARK: - Recommendations

    func test_loadRecommendations_populatesRecommendedModels() {
        let mock = MockHuggingFaceService()
        let vm = ModelManagementViewModel(huggingFaceService: mock)

        vm.loadRecommendations()

        XCTAssertFalse(vm.recommendedModels.isEmpty, "recommendedModels should be non-empty after loading")
    }

    func test_loadRecommendations_matchesDeviceTier() {
        let mock = MockHuggingFaceService()

        // 6 GB RAM -> small tier
        let smallDevice = DeviceCapabilityService(physicalMemory: 6 * oneGB)
        let vmSmall = ModelManagementViewModel(
            huggingFaceService: mock,
            deviceCapability: smallDevice
        )
        vmSmall.loadRecommendations()

        XCTAssertEqual(vmSmall.recommendation, .small, "6 GB device should be .small tier")

        // Verify all recommended models are in the curated list for .small
        let expectedSmall = CuratedModel.all
            .filter { $0.recommendedFor.contains(.small) }
            .map { $0.displayName }
        for model in vmSmall.recommendedModels {
            XCTAssertTrue(
                expectedSmall.contains(model.displayName),
                "\(model.displayName) should be recommended for small tier"
            )
        }

        // 10 GB RAM -> large tier
        let largeDevice = DeviceCapabilityService(physicalMemory: 10 * oneGB)
        let vmLarge = ModelManagementViewModel(
            huggingFaceService: mock,
            deviceCapability: largeDevice
        )
        vmLarge.loadRecommendations()

        XCTAssertEqual(vmLarge.recommendation, .large, "10 GB device should be .large tier")
        XCTAssertGreaterThan(
            vmLarge.recommendedModels.count,
            vmSmall.recommendedModels.count,
            "Large tier should have more recommendations than small tier"
        )
    }

    // MARK: - Search

    func test_search_emptyQuery_clearsResults() async {
        let mock = MockHuggingFaceService()
        mock.searchResults = [
            DownloadableModel(
                repoID: "test/repo",
                fileName: "test.gguf",
                displayName: "Test",
                modelType: .gguf,
                sizeBytes: 1_000_000
            )
        ]
        let vm = ModelManagementViewModel(huggingFaceService: mock)

        vm.searchQuery = ""
        await vm.search()

        XCTAssertTrue(vm.searchResults.isEmpty, "Empty query should clear search results")
        XCTAssertNil(vm.searchError, "Empty query should clear search error")
    }

    func test_search_withResults_populatesSearchResults() async {
        let mock = MockHuggingFaceService()
        let expected = [
            DownloadableModel(
                repoID: "test/repo",
                fileName: "model-q4.gguf",
                displayName: "Test Model Q4",
                modelType: .gguf,
                sizeBytes: 4_000_000_000
            ),
            DownloadableModel(
                repoID: "test/repo2",
                fileName: "model-q6.gguf",
                displayName: "Test Model Q6",
                modelType: .gguf,
                sizeBytes: 5_000_000_000
            )
        ]
        mock.searchResults = expected

        let vm = ModelManagementViewModel(huggingFaceService: mock)
        vm.searchQuery = "test model"
        await vm.search()

        XCTAssertEqual(vm.searchResults.count, 2, "Should populate two search results")
        XCTAssertEqual(vm.searchResults.first?.displayName, "Test Model Q4")
        XCTAssertNil(vm.searchError, "Successful search should not set error")
    }

    func test_search_withError_setsSearchError() async {
        let mock = MockHuggingFaceService()
        mock.searchError = NSError(domain: "test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Network unavailable"
        ])

        let vm = ModelManagementViewModel(huggingFaceService: mock)
        vm.searchQuery = "test"
        await vm.search()

        XCTAssertNotNil(vm.searchError, "Failed search should set searchError")
        XCTAssertTrue(
            vm.searchError?.contains("Search failed") ?? false,
            "Error message should indicate search failure"
        )
    }

    // MARK: - Device Capability Queries

    func test_canRunModel_delegatesToDeviceCapability() {
        // 16 GB device: should handle a 4 GB model.
        let largeDevice = DeviceCapabilityService(physicalMemory: 16 * oneGB)
        let vmLarge = ModelManagementViewModel(deviceCapability: largeDevice)

        XCTAssertTrue(
            vmLarge.canRunModel(sizeBytes: 4_000_000_000),
            "16 GB device should be able to run a 4 GB model"
        )

        // 4 GB device: should NOT handle a 4 GB model (need room for KV cache + OS).
        let smallDevice = DeviceCapabilityService(physicalMemory: 4 * oneGB)
        let vmSmall = ModelManagementViewModel(deviceCapability: smallDevice)

        XCTAssertFalse(
            vmSmall.canRunModel(sizeBytes: 4_000_000_000),
            "4 GB device should not be able to run a 4 GB model"
        )
    }

    func test_isModelDownloaded_checksStorage() {
        // With default ModelStorageService and a model that doesn't exist on disk,
        // isModelDownloaded should return false.
        let vm = ModelManagementViewModel()

        let model = DownloadableModel(
            repoID: "test/nonexistent",
            fileName: "nonexistent-model-\(UUID().uuidString).gguf",
            displayName: "Nonexistent Model",
            modelType: .gguf,
            sizeBytes: 1_000_000
        )

        XCTAssertFalse(
            vm.isModelDownloaded(model),
            "Model with unique filename should not be found on disk"
        )
    }

    // MARK: - Downloads

    func test_startDownload_withNoDownloadManager_setsError() {
        let mock = MockHuggingFaceService()
        let vm = ModelManagementViewModel(
            huggingFaceService: mock,
            downloadManager: nil
        )

        let model = DownloadableModel(
            repoID: "test/repo",
            fileName: "test.gguf",
            displayName: "Test",
            modelType: .gguf,
            sizeBytes: 1_000_000
        )

        vm.startDownload(model)

        XCTAssertNotNil(vm.searchError, "Starting download with nil manager should set error")
        XCTAssertTrue(
            vm.searchError?.contains("Download manager") ?? false,
            "Error should mention download manager"
        )
    }
}

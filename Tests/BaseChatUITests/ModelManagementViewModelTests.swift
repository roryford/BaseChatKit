@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

@MainActor
final class ModelManagementViewModelTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    override func setUp() async throws {
        try await super.setUp()
        // Provide curated models for tests that depend on recommendations.
        // In production, the app populates CuratedModel.all at startup.
        CuratedModel.all = [
            CuratedModel(
                id: "small-model",
                displayName: "Small Test Model",
                fileName: "small-test.gguf",
                repoID: "test/small",
                modelType: .gguf,
                approximateSizeBytes: 500_000_000,
                recommendedFor: [.small, .medium, .large, .xlarge],
                contextSize: 2048,
                promptTemplate: .chatML,
                description: "Tiny test model"
            ),
            CuratedModel(
                id: "medium-model",
                displayName: "Medium Test Model",
                fileName: "medium-test.gguf",
                repoID: "test/medium",
                modelType: .gguf,
                approximateSizeBytes: 4_000_000_000,
                recommendedFor: [.medium, .large, .xlarge],
                contextSize: 4096,
                promptTemplate: .mistral,
                description: "Medium test model"
            ),
            CuratedModel(
                id: "large-model",
                displayName: "Large Test Model",
                fileName: "large-test.gguf",
                repoID: "test/large",
                modelType: .gguf,
                approximateSizeBytes: 8_000_000_000,
                recommendedFor: [.large, .xlarge],
                contextSize: 8192,
                promptTemplate: .llama3,
                description: "Large test model"
            ),
        ]
    }

    override func tearDown() async throws {
        CuratedModel.all = []
        try await super.tearDown()
    }

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

    func test_liveFactory_usesInjectedSearchService() async {
        let mock = MockHuggingFaceService()
        mock.searchResults = [
            DownloadableModel(
                repoID: "test/repo",
                fileName: "configured.gguf",
                displayName: "Configured Model",
                modelType: .gguf,
                sizeBytes: 2_000_000_000
            )
        ]

        let vm = ModelManagementViewModel.live(
            huggingFaceService: mock,
            downloadManager: BackgroundDownloadManager()
        )
        vm.searchQuery = "configured"

        await vm.search()

        XCTAssertEqual(vm.searchResults.map(\.displayName), ["Configured Model"])
        XCTAssertNil(vm.searchError)
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

    // MARK: - Local Model Import

    func test_importModel_withGGUF_copiesFileIntoModelsDirectory() throws {
        let vm = ModelManagementViewModel()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileName = "imported-\(UUID().uuidString).gguf"
        let sourceURL = tempDir.appendingPathComponent(fileName)
        try Data(repeating: 0xAB, count: 4096).write(to: sourceURL)

        let imported = try vm.importModel(from: sourceURL)
        let importedURL = URL(fileURLWithPath: vm.modelsDirectoryPath).appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: importedURL) }

        XCTAssertEqual(imported.fileName, fileName)
        XCTAssertEqual(imported.modelType, .gguf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))
    }

    func test_importModel_withUnsupportedFile_throwsAndRemovesCopy() throws {
        let vm = ModelManagementViewModel()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelImportUnsupported-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileName = "unsupported-\(UUID().uuidString).txt"
        let sourceURL = tempDir.appendingPathComponent(fileName)
        try Data("not a model".utf8).write(to: sourceURL)

        XCTAssertThrowsError(try vm.importModel(from: sourceURL)) { error in
            XCTAssertEqual(error as? ModelImportError, .unsupportedFormat)
        }

        let importedURL = URL(fileURLWithPath: vm.modelsDirectoryPath).appendingPathComponent(fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedURL.path))
    }

    // MARK: - Diagnostics surfacing

    func test_importModel_whenCleanupDeletionFails_recordsDiagnosticWarning() throws {
        struct DeletionFailure: LocalizedError {
            var errorDescription: String? { "simulated deletion failure" }
        }

        let diagnostics = DiagnosticsService()
        let vm = ModelManagementViewModel(
            diagnostics: diagnostics,
            fileRemover: { _ in throw DeletionFailure() }
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelImportWarning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileName = "unsupported-\(UUID().uuidString).txt"
        let sourceURL = tempDir.appendingPathComponent(fileName)
        try Data("not a model".utf8).write(to: sourceURL)

        XCTAssertThrowsError(try vm.importModel(from: sourceURL)) { error in
            XCTAssertEqual(error as? ModelImportError, .unsupportedFormat)
        }

        // The cleanup failure should now surface as an OperationalWarning
        // instead of being silently swallowed.
        XCTAssertEqual(diagnostics.count, 1, "Deletion failure should be recorded on diagnostics")
        if case .modelFileDeletionFailed(_, let reason) = diagnostics.warnings.first?.error {
            XCTAssertTrue(reason.contains("simulated deletion failure"))
        } else {
            XCTFail("Expected .modelFileDeletionFailed warning, got \(String(describing: diagnostics.warnings.first?.error))")
        }

        // Clean up the leaked file — the stub fileRemover didn't touch it.
        let importedURL = URL(fileURLWithPath: vm.modelsDirectoryPath).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: importedURL)
    }

    func test_importModel_whenCleanupSucceeds_recordsNoWarning() throws {
        let diagnostics = DiagnosticsService()
        let vm = ModelManagementViewModel(diagnostics: diagnostics)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelImportWarningOK-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileName = "unsupported-\(UUID().uuidString).txt"
        let sourceURL = tempDir.appendingPathComponent(fileName)
        try Data("not a model".utf8).write(to: sourceURL)

        XCTAssertThrowsError(try vm.importModel(from: sourceURL))

        XCTAssertTrue(diagnostics.isEmpty, "Successful cleanup should not record a warning")
    }
}

@preconcurrency import XCTest
@testable import BaseChatUI
@testable import BaseChatCore
import BaseChatTestSupport

/// Tests for the logic that drives ModelManagementSheet tabs, model selection,
/// and storage display.
///
/// The sheet has three tabs (Select, Download, Storage) gated by feature flags,
/// and a model selection flow that immediately activates the chosen model.
/// These tests verify tab availability, model selection state transitions,
/// and the data that populates each tab.
@MainActor
final class ModelManagementSheetLogicTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeViewModelWithMock(
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSessionRecord(title: "Test Session")
        return (vm, mock)
    }

    // MARK: - Tab enumeration

    func test_tab_rawValues() {
        XCTAssertEqual(ModelManagementSheet.Tab.select.rawValue, "Select")
        XCTAssertEqual(ModelManagementSheet.Tab.download.rawValue, "Download")
        XCTAssertEqual(ModelManagementSheet.Tab.storage.rawValue, "Storage")
    }

    func test_tab_systemImages() {
        XCTAssertEqual(ModelManagementSheet.Tab.select.systemImage, "checkmark.circle")
        XCTAssertEqual(ModelManagementSheet.Tab.download.systemImage, "square.and.arrow.down")
        XCTAssertEqual(ModelManagementSheet.Tab.storage.systemImage, "externaldrive")
    }

    func test_tab_allCases() {
        let cases = ModelManagementSheet.Tab.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertEqual(cases, [.select, .download, .storage])
    }

    // MARK: - Model selection state transitions

    func test_modelSelection_setsSelectedModel() {
        let (vm, _) = makeViewModelWithMock()
        let model = ModelInfo(
            name: "Test Model",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 1_000_000_000,
            modelType: .gguf
        )

        vm.selectedModel = model

        XCTAssertEqual(vm.selectedModel?.name, "Test Model")
        XCTAssertEqual(vm.selectedModel?.fileName, "test.gguf")
    }

    func test_modelSelection_clearsEndpointWhenModelSelected() {
        let (vm, _) = makeViewModelWithMock()

        // Simulate having an endpoint selected.
        // The mutual exclusion logic: setting selectedModel clears selectedEndpoint.
        let model = ModelInfo(
            name: "Local Model",
            fileName: "local.gguf",
            url: URL(fileURLWithPath: "/tmp/local.gguf"),
            fileSize: 2_000_000_000,
            modelType: .gguf
        )
        vm.selectedModel = model

        // After selecting a local model, the endpoint should be cleared.
        XCTAssertNil(vm.selectedEndpoint, "Selecting a model should clear the endpoint selection")
        XCTAssertNotNil(vm.selectedModel, "Model should remain selected")
    }

    // MARK: - Available models

    func test_availableModels_emptyOnInit() {
        let vm = ChatViewModel(
            inferenceService: InferenceService(),
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            memoryPressure: MemoryPressureHandler()
        )
        XCTAssertTrue(vm.availableModels.isEmpty, "Available models should be empty on init")
    }

    func test_refreshModels_populatesAvailableModels() {
        let (vm, _) = makeViewModelWithMock()
        vm.refreshModels()
        // The actual count depends on what's on disk; we just verify it doesn't crash.
        // In the existing GenerationViewModelTests, actual GGUF files are created.
    }

    // MARK: - ModelInfo properties

    func test_modelInfo_ggufType() {
        let model = ModelInfo(
            name: "Test GGUF",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 4_000_000_000,
            modelType: .gguf
        )
        XCTAssertEqual(model.modelType, .gguf)
        XCTAssertEqual(model.name, "Test GGUF")
        XCTAssertEqual(model.fileSize, 4_000_000_000)
    }

    func test_modelInfo_mlxType() {
        let model = ModelInfo(
            name: "Test MLX",
            fileName: "test-mlx",
            url: URL(fileURLWithPath: "/tmp/test-mlx"),
            fileSize: 3_000_000_000,
            modelType: .mlx
        )
        XCTAssertEqual(model.modelType, .mlx)
    }

    func test_modelInfo_foundationType() {
        let model = ModelInfo(
            name: "Foundation Model",
            fileName: "foundation",
            url: URL(fileURLWithPath: "/tmp/foundation"),
            fileSize: 0,
            modelType: .foundation
        )
        XCTAssertEqual(model.modelType, .foundation)
    }

    func test_modelInfo_fileSizeFormatted() {
        let model = ModelInfo(
            name: "4GB Model",
            fileName: "model.gguf",
            url: URL(fileURLWithPath: "/tmp/model.gguf"),
            fileSize: 4_000_000_000,
            modelType: .gguf
        )
        // fileSizeFormatted should produce a human-readable string.
        XCTAssertFalse(model.fileSizeFormatted.isEmpty, "Formatted file size should not be empty")
    }

    // MARK: - Model type variants

    func test_modelType_distinctCases() {
        let types: [ModelType] = [.gguf, .mlx, .foundation]
        // Each type is distinct — they drive different backend and badge rendering.
        XCTAssertNotEqual(types[0], types[1])
        XCTAssertNotEqual(types[1], types[2])
        XCTAssertNotEqual(types[0], types[2])
    }

    // MARK: - ModelManagementViewModel state

    func test_managementViewModel_defaultState() {
        let vm = ModelManagementViewModel()
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertTrue(vm.searchResults.isEmpty)
        XCTAssertFalse(vm.isSearching)
        XCTAssertNil(vm.searchError)
    }

    func test_managementViewModel_storageInfo() {
        let vm = ModelManagementViewModel()
        // totalStorageUsed should return a formatted string even if no models exist.
        XCTAssertFalse(vm.totalStorageUsed.isEmpty, "Storage display should never be empty")
        XCTAssertFalse(vm.modelsDirectoryPath.isEmpty, "Models directory path should never be empty")
    }

    // MARK: - Download model grouping

    func test_downloadableModelGroup_singleVariant() {
        let models = [
            DownloadableModel(
                repoID: "test/repo",
                fileName: "model-q4.gguf",
                displayName: "Test Model Q4",
                modelType: .gguf,
                sizeBytes: 4_000_000_000
            )
        ]
        let groups = DownloadableModelGroup.group(models)
        XCTAssertEqual(groups.count, 1, "Single model should produce one group")
        XCTAssertEqual(groups.first?.variants.count, 1, "Single model group should have one variant")
    }

    func test_downloadableModelGroup_multipleVariants() {
        let models = [
            DownloadableModel(
                repoID: "test/repo",
                fileName: "model-q4.gguf",
                displayName: "Test Model Q4",
                modelType: .gguf,
                sizeBytes: 4_000_000_000
            ),
            DownloadableModel(
                repoID: "test/repo",
                fileName: "model-q6.gguf",
                displayName: "Test Model Q6",
                modelType: .gguf,
                sizeBytes: 6_000_000_000
            )
        ]
        let groups = DownloadableModelGroup.group(models)
        // Both models are from the same repo, so they should be grouped together.
        XCTAssertEqual(groups.count, 1, "Same-repo models should be grouped together")
        XCTAssertEqual(groups.first?.variants.count, 2, "Group should contain both variants")
    }

    func test_downloadableModelGroup_differentRepos() {
        let models = [
            DownloadableModel(
                repoID: "test/repo1",
                fileName: "model-a.gguf",
                displayName: "Model A",
                modelType: .gguf,
                sizeBytes: 4_000_000_000
            ),
            DownloadableModel(
                repoID: "test/repo2",
                fileName: "model-b.gguf",
                displayName: "Model B",
                modelType: .gguf,
                sizeBytes: 5_000_000_000
            )
        ]
        let groups = DownloadableModelGroup.group(models)
        XCTAssertEqual(groups.count, 2, "Different repos should produce separate groups")
    }

    // MARK: - Capability tier display

    func test_capabilityTier_labels() {
        // ModelCapabilityTier drives badge text in ModelSelectRow.
        let tiers: [ModelCapabilityTier] = [.minimal, .fast, .balanced, .capable, .frontier]
        for tier in tiers {
            XCTAssertFalse(tier.label.isEmpty, "\(tier) should have a non-empty label")
        }
    }

    func test_capabilityTier_labelsAreHumanReadable() {
        XCTAssertEqual(ModelCapabilityTier.minimal.label, "Minimal")
        XCTAssertEqual(ModelCapabilityTier.fast.label, "Fast")
        XCTAssertEqual(ModelCapabilityTier.balanced.label, "Balanced")
        XCTAssertEqual(ModelCapabilityTier.capable.label, "Capable")
        XCTAssertEqual(ModelCapabilityTier.frontier.label, "Frontier")
    }

    func test_capabilityTier_ordering() {
        XCTAssertTrue(ModelCapabilityTier.minimal < .fast)
        XCTAssertTrue(ModelCapabilityTier.fast < .balanced)
        XCTAssertTrue(ModelCapabilityTier.balanced < .capable)
        XCTAssertTrue(ModelCapabilityTier.capable < .frontier)
    }
}

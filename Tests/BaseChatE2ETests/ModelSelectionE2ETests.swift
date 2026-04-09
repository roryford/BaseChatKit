import Testing
import Foundation
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
import BaseChatTestSupport

/// E2E tests for the model selection and loading pipeline.
///
/// Covers the full chain from disk discovery through selection, load, and
/// generation, plus session persistence of the selected model ID.
///
/// Uses `MockInferenceBackend` and a temp directory for model files so no
/// hardware or real models are needed.
@Suite("Model Selection E2E")
@MainActor
final class ModelSelectionE2ETests {

    private let container: ModelContainer
    private let context: ModelContext
    private let mock: MockInferenceBackend
    private let vm: ChatViewModel
    private let sessionManager: SessionManagerViewModel
    private let modelsDir: URL

    init() throws {
        modelsDir = try makeE2ETempDir()

        container = try ModelContainerFactory.makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()

        // Register a factory so InferenceService.loadModel() routes through
        // the mock rather than a real backend. The factory returns the same
        // mock instance for any model type so call counts accumulate correctly.
        let mockRef = mock
        let service = InferenceService()
        service.registerBackendFactory { _ in mockRef }

        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        let storage = ModelStorageService(baseDirectory: modelsDir)
        vm = ChatViewModel(inferenceService: service, modelStorage: storage)
        vm.configure(persistence: persistence)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence)
    }

    deinit {
        cleanupE2ETempDir(modelsDir)
    }

    // MARK: - Helpers

    private func makeSession(title: String = "Test") throws -> ChatSessionRecord {
        let session = try sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        vm.switchToSession(session)
        return session
    }

    /// Writes a minimal valid GGUF file to `modelsDir`.
    @discardableResult
    private func writeGGUF(named name: String = "test-model.gguf") throws -> URL {
        let url = modelsDir.appendingPathComponent(name)
        var data = Data(ggufMagic)
        data.append(Data(repeating: 0xFF, count: 1_100_000))
        try data.write(to: url)
        return url
    }

    // MARK: - Discovery

    @Test("refreshModels discovers a GGUF file written to the models directory")
    func refreshModels_discoversGGUF() throws {
        try writeGGUF()

        vm.refreshModels()

        #expect(vm.availableModels.count == 1)
        #expect(vm.availableModels[0].modelType == .gguf)

        // Sabotage: without the file, no models are found.
        try FileManager.default.removeItem(at: modelsDir.appendingPathComponent("test-model.gguf"))
        vm.refreshModels()
        #expect(vm.availableModels.isEmpty)
    }

    @Test("refreshModels discovers an MLX model directory")
    func refreshModels_discoversMLXDirectory() throws {
        let mlxDir = modelsDir.appendingPathComponent("my-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"llama\"}".utf8)
            .write(to: mlxDir.appendingPathComponent("config.json"))
        // MLX validation requires at least one .safetensors file since #148.
        try Data(repeating: 0x00, count: 1)
            .write(to: mlxDir.appendingPathComponent("weights.safetensors"))

        vm.refreshModels()

        #expect(vm.availableModels.count == 1)
        #expect(vm.availableModels[0].modelType == .mlx)
    }

    // MARK: - Select → Load → Generate

    @Test("Selecting a model and loading it marks the backend as loaded")
    func selectAndLoad_backendBecomesLoaded() async throws {
        let model = ModelInfo(
            name: "Test GGUF",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 400_000_000,
            modelType: .gguf
        )

        vm.selectedModel = model
        #expect(!vm.isModelLoaded)

        await vm.loadSelectedModel()

        #expect(vm.isModelLoaded)
        #expect(mock.loadModelCallCount == 1)
        #expect(vm.errorMessage == nil)

        // Sabotage: if loadSelectedModel() had not been called, load count would still be 0.
        #expect(mock.loadModelCallCount != 0)
    }

    @Test("After loading, sendMessage generates a response")
    func selectLoadSend_producesResponse() async throws {
        try makeSession()

        let model = ModelInfo(
            name: "Test GGUF",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 400_000_000,
            modelType: .gguf
        )
        vm.selectedModel = model
        await vm.loadSelectedModel()
        #expect(vm.isModelLoaded)

        mock.tokensToYield = ["Hello", " world"]
        vm.inputText = "Hi"
        await vm.sendMessage()

        #expect(vm.messages.count == 2)
        #expect(vm.messages[0].role == .user)
        #expect(vm.messages[1].role == .assistant)
        #expect(vm.messages[1].content == "Hello world")
    }

    // MARK: - Model Switching

    @Test("Switching to a different model calls load a second time")
    func switchModel_loadsNewBackend() async throws {
        let modelA = ModelInfo(
            name: "Model A",
            fileName: "a.gguf",
            url: URL(fileURLWithPath: "/tmp/a.gguf"),
            fileSize: 400_000_000,
            modelType: .gguf
        )
        let modelB = ModelInfo(
            name: "Model B",
            fileName: "b.gguf",
            url: URL(fileURLWithPath: "/tmp/b.gguf"),
            fileSize: 400_000_000,
            modelType: .gguf
        )

        vm.selectedModel = modelA
        await vm.loadSelectedModel()
        #expect(mock.loadModelCallCount == 1)

        vm.selectedModel = modelB
        await vm.loadSelectedModel()
        #expect(mock.loadModelCallCount == 2)
    }

    // MARK: - Memory Guard

    @Test("Model too large for device sets an error and skips load")
    func modelTooLarge_setsError() async throws {
        let mockRef = mock
        let storage = ModelStorageService(baseDirectory: modelsDir)

        // 1 MB of RAM — far too small for any real model.
        let tinyDevice = DeviceCapabilityService(physicalMemory: 1_000_000)
        let restrictedService = InferenceService()
        restrictedService.registerBackendFactory { _ in mockRef }
        let restrictedVM = ChatViewModel(
            inferenceService: restrictedService,
            deviceCapability: tinyDevice,
            modelStorage: storage
        )

        let bigModel = ModelInfo(
            name: "Big Model",
            fileName: "big.gguf",
            url: URL(fileURLWithPath: "/tmp/big.gguf"),
            fileSize: 400_000_000,
            modelType: .gguf
        )
        restrictedVM.selectedModel = bigModel
        await restrictedVM.loadSelectedModel()

        #expect(mock.loadModelCallCount == 0)
        #expect(restrictedVM.errorMessage != nil)
        #expect(!restrictedVM.isModelLoaded)

        // Sabotage: with enough RAM, the load should proceed.
        let largeDevice = DeviceCapabilityService(physicalMemory: 32 * 1024 * 1024 * 1024)
        let permissiveService = InferenceService()
        permissiveService.registerBackendFactory { _ in mockRef }
        let permissiveVM = ChatViewModel(
            inferenceService: permissiveService,
            deviceCapability: largeDevice,
            modelStorage: storage
        )
        permissiveVM.selectedModel = bigModel
        await permissiveVM.loadSelectedModel()
        #expect(mock.loadModelCallCount == 1)
    }

    // MARK: - Disk Removal

    @Test("refreshModels clears selectedModel when the file is deleted from disk")
    func refreshModels_clearsSelectedModelOnDeletion() throws {
        let ggufURL = try writeGGUF()
        vm.refreshModels()

        let discovered = try #require(vm.availableModels.first)
        vm.selectedModel = discovered
        #expect(vm.selectedModel != nil)

        // Delete the file and refresh — selectedModel must be cleared.
        try FileManager.default.removeItem(at: ggufURL)
        vm.refreshModels()

        #expect(vm.availableModels.isEmpty)
        #expect(vm.selectedModel == nil)
    }

    // MARK: - Session Persistence

    @Test("Selected model ID is persisted to session and restored on switch-back")
    func sessionRestoresSelectedModel() throws {
        // Write two distinct GGUFs so each session can have a different model.
        try writeGGUF(named: "model-a.gguf")
        try writeGGUF(named: "model-b.gguf")
        vm.refreshModels()
        let models = vm.availableModels
        #expect(models.count == 2)
        let modelA = models[0]
        let modelB = models[1]

        // Session A selects model A.
        try makeSession(title: "Session A")
        vm.selectedModel = modelA
        try vm.saveSettingsToSession()

        // Session B selects model B.
        let sessionB = try sessionManager.createSession(title: "Session B")
        sessionManager.activeSession = sessionB
        vm.switchToSession(sessionB)
        vm.selectedModel = modelB
        try vm.saveSettingsToSession()

        // Reload sessions from persistence so we have fresh records with the
        // saved selectedModelIDs (ChatSessionRecord is a value type).
        sessionManager.loadSessions()
        let freshA = try #require(sessionManager.sessions.first { $0.title == "Session A" })

        // Switch back to session A using the fresh record — model A should restore.
        sessionManager.activeSession = freshA
        vm.switchToSession(freshA)
        #expect(vm.selectedModel?.id == modelA.id)

        // Sabotage: delete model A's file so availableModels drops it,
        // then confirm the session restore fails gracefully.
        let modelAURL = modelsDir.appendingPathComponent("model-a.gguf")
        try FileManager.default.removeItem(at: modelAURL)
        vm.refreshModels()
        let freshA2 = try #require(sessionManager.sessions.first { $0.title == "Session A" })
        vm.switchToSession(freshA2)
        #expect(vm.selectedModel == nil, "Model not restored when not in availableModels")
    }
}

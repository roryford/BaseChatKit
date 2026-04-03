import XCTest
@testable import BaseChatUI
@testable import BaseChatCore
import BaseChatTestSupport

/// E2E test for the memory pressure -> model unload pipeline.
///
/// Wires `MemoryPressureHandler` through `ChatViewModel` to `InferenceService`
/// with a real backend mock, verifying the full chain: pressure level change ->
/// generation stops -> model unloads -> user-facing state updates.
///
/// Uses `MockInferenceBackend` rather than a real ML backend so the test runs
/// without hardware. The DispatchSource-based handler is tested at the unit level;
/// here we set `pressureLevel` directly to simulate OS events deterministically.
@MainActor
final class MemoryPressureUnloadE2ETests: XCTestCase {

    // MARK: - Helpers

    private let sixteenGB: UInt64 = 16 * 1_024 * 1_024 * 1_024

    /// Builds a fully-wired ChatViewModel with injectable pressure handler and mock backend.
    private func makeViewModel(
        handler: MemoryPressureHandler = MemoryPressureHandler(),
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend, MemoryPressureHandler) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: sixteenGB),
            modelStorage: ModelStorageService(),
            memoryPressure: handler
        )
        vm.activeSession = ChatSessionRecord(title: "E2E Pressure Test")
        return (vm, mock, handler)
    }

    // MARK: - Full Lifecycle: nominal -> critical -> nominal

    /// Exercises the complete memory pressure lifecycle through the real wiring:
    /// 1. Model is loaded and generation works.
    /// 2. Critical pressure fires -> model unloads, isModelLoaded becomes false,
    ///    error message is shown.
    /// 3. Pressure returns to nominal -> error clears.
    func test_fullLifecycle_criticalUnloadsThenNominalRecovers() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = makeViewModel(handler: handler)

        // --- Phase 1: Healthy state ---
        XCTAssertTrue(vm.inferenceService.isModelLoaded,
            "Precondition: model should be loaded")
        XCTAssertNil(vm.errorMessage,
            "Precondition: no error message")
        XCTAssertEqual(vm.memoryPressureLevel, .nominal,
            "Precondition: pressure should be nominal")
        XCTAssertEqual(mock.unloadCallCount, 0)

        // Verify generation works before pressure event.
        mock.tokensToYield = ["Hello"]
        vm.inputText = "Test prompt"
        await vm.sendMessage()
        XCTAssertFalse(vm.messages.isEmpty,
            "Should have messages after successful generation")

        // --- Phase 2: Critical pressure fires ---
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        // InferenceService.unloadModel() should have been called.
        XCTAssertEqual(mock.unloadCallCount, 1,
            "unloadModel should be called once at critical pressure")
        XCTAssertFalse(mock.isModelLoaded,
            "Backend should report model unloaded")
        XCTAssertFalse(vm.inferenceService.isModelLoaded,
            "InferenceService.isModelLoaded should be false after critical pressure")

        // User-facing error should explain the unload.
        XCTAssertNotNil(vm.errorMessage,
            "Error message should be set after critical pressure")
        XCTAssertTrue(
            vm.errorMessage?.lowercased().contains("critical") == true
            || vm.errorMessage?.lowercased().contains("unload") == true,
            "Error should mention critical pressure or unloading, got: \(vm.errorMessage ?? "nil")"
        )

        // --- Phase 3: Pressure returns to nominal ---
        handler.pressureLevel = .nominal
        vm.handleMemoryPressure()

        XCTAssertNil(vm.errorMessage,
            "Error message should be cleared when pressure returns to nominal")
        // Model stays unloaded -- the user must reload manually.
        XCTAssertFalse(vm.inferenceService.isModelLoaded,
            "Model should remain unloaded after pressure clears (manual reload required)")
    }

    // MARK: - Warning Does Not Unload

    /// Warning-level pressure should set an advisory error but NOT unload the model.
    func test_warningPressure_doesNotUnloadModel() {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = makeViewModel(handler: handler)

        handler.pressureLevel = .warning
        vm.handleMemoryPressure()

        XCTAssertTrue(vm.inferenceService.isModelLoaded,
            "Model should remain loaded at warning level")
        XCTAssertEqual(mock.unloadCallCount, 0,
            "unloadModel should NOT be called at warning level")
        XCTAssertNotNil(vm.errorMessage,
            "Advisory error message should be set at warning level")
    }

    // MARK: - Critical During Generation

    /// If memory pressure goes critical while generation is in progress,
    /// the model should be unloaded and generation stopped.
    func test_criticalDuringGeneration_stopsAndUnloads() async throws {
        let slow = SlowMockBackend()
        slow.tokensToYield = (0..<30).map { "tok\($0) " }
        slow.delayPerToken = .milliseconds(50)

        let handler = MemoryPressureHandler()
        let service = InferenceService(backend: slow, name: "SlowMock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: sixteenGB),
            modelStorage: ModelStorageService(),
            memoryPressure: handler
        )
        vm.activeSession = ChatSessionRecord(title: "Pressure During Gen")

        // Start a slow generation.
        vm.inputText = "Tell me something long"
        let genTask = Task { @MainActor in
            await vm.sendMessage()
        }

        // Wait for generation to begin streaming.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(vm.isGenerating, "Precondition: should be generating")

        // Simulate critical memory pressure mid-generation.
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        // Model should be unloaded immediately.
        XCTAssertFalse(vm.inferenceService.isModelLoaded,
            "Model should be unloaded after critical pressure during generation")

        // Wait for the generation task to finish (it should exit gracefully).
        await genTask.value

        XCTAssertNotNil(vm.errorMessage,
            "Error message should be set after critical pressure during generation")
    }

    // MARK: - Escalation: warning -> critical

    /// Pressure escalating from warning to critical should trigger unload on the
    /// critical transition, not on the initial warning.
    func test_escalation_warningThenCritical_unloadsOnCritical() {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = makeViewModel(handler: handler)

        // Step 1: warning -- no unload.
        handler.pressureLevel = .warning
        vm.handleMemoryPressure()
        XCTAssertEqual(mock.unloadCallCount, 0,
            "No unload at warning level")
        XCTAssertTrue(vm.inferenceService.isModelLoaded,
            "Model should still be loaded at warning")

        // Step 2: escalate to critical -- unload fires.
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()
        XCTAssertEqual(mock.unloadCallCount, 1,
            "unloadModel should fire when escalating to critical")
        XCTAssertFalse(vm.inferenceService.isModelLoaded,
            "Model should be unloaded after critical escalation")
    }

    // MARK: - Repeated Critical Is Idempotent

    /// Calling handleMemoryPressure twice at critical level should only unload once.
    func test_repeatedCritical_unloadsOnlyOnce() {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = makeViewModel(handler: handler)

        handler.pressureLevel = .critical
        vm.handleMemoryPressure()
        vm.handleMemoryPressure()

        XCTAssertEqual(mock.unloadCallCount, 1,
            "Second critical call should be a no-op (same level guard)")
    }

    // MARK: - memoryPressureLevel Reflects Handler

    /// The view model's `memoryPressureLevel` computed property should always
    /// reflect the handler's current state.
    func test_memoryPressureLevel_reflectsHandler() {
        let handler = MemoryPressureHandler()
        let (vm, _, _) = makeViewModel(handler: handler)

        XCTAssertEqual(vm.memoryPressureLevel, .nominal)

        handler.pressureLevel = .warning
        XCTAssertEqual(vm.memoryPressureLevel, .warning)

        handler.pressureLevel = .critical
        XCTAssertEqual(vm.memoryPressureLevel, .critical)

        handler.pressureLevel = .nominal
        XCTAssertEqual(vm.memoryPressureLevel, .nominal)
    }
}

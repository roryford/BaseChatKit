@preconcurrency import XCTest
@testable import BaseChatUI
@testable import BaseChatCore

/// Tests for the ChatViewModel ↔ InferenceService.modelLoadProgress bridge.
///
/// Verifies that ChatViewModel mirrors `inferenceService.modelLoadProgress` into
/// `activityPhase = .modelLoading(progress:)` while a load is in flight, and
/// resets to `.idle` when the load completes.
@MainActor
final class ChatViewModelLoadProgressBridgeTests: XCTestCase {

    private func makeModelInfo(name: String = "Bridge", modelType: ModelType = .gguf) -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).bin",
            url: URL(fileURLWithPath: "/\(name).bin"),
            fileSize: 0,
            modelType: modelType
        )
    }

    private func waitForPhase(
        _ expected: BackendActivityPhase,
        on vm: ChatViewModel,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if vm.activityPhase == expected { return }
        let expectation = XCTestExpectation(description: "activityPhase == \(expected)")
        let previous = vm.onActivityPhaseChanged
        vm.onActivityPhaseChanged = { phase in
            previous?(phase)
            if phase == expected { expectation.fulfill() }
        }
        let result = await XCTWaiter().fulfillment(of: [expectation], timeout: timeout)
        vm.onActivityPhaseChanged = previous
        if result != .completed {
            XCTFail("Timed out waiting for activityPhase \(expected) — current: \(vm.activityPhase)",
                    file: file, line: line)
        }
    }

    // MARK: - Reporting backend

    func test_activityPhase_reflectsProgressFromReportingBackend() async throws {
        let backend = ProgressBridgeBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let vm = ChatViewModel(inferenceService: service)
        vm.progressBridgePollInterval = .milliseconds(2)
        vm.selectedModel = makeModelInfo()

        let loadTask = Task { await vm.loadSelectedModel() }
        await backend.waitUntilLoadStarted()

        // Bridge should publish 0.0 first (the seed value from beginLoadRequest).
        await waitForPhase(.modelLoading(progress: 0.0), on: vm)

        await backend.fireProgress(0.4)
        await waitForPhase(.modelLoading(progress: 0.4), on: vm)

        await backend.fireProgress(0.85)
        await waitForPhase(.modelLoading(progress: 0.85), on: vm)

        await backend.releaseLoadSuccess()
        await loadTask.value

        // Once the load commits, activityPhase should return to .idle.
        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertTrue(vm.isModelLoaded)
    }

    // MARK: - Non-reporting backend

    func test_activityPhase_staysAtZero_whenBackendDoesNotReportProgress() async throws {
        let backend = PlainBridgeBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let vm = ChatViewModel(inferenceService: service)
        vm.progressBridgePollInterval = .milliseconds(2)
        vm.selectedModel = makeModelInfo()

        let loadTask = Task { await vm.loadSelectedModel() }
        await backend.waitUntilLoadStarted()

        // For a non-reporting backend, the service still seeds modelLoadProgress
        // to 0.0 at load start. The bridge should publish that and never
        // produce any fractional value.
        await waitForPhase(.modelLoading(progress: 0.0), on: vm)

        // Hold for a few poll intervals and confirm nothing else appears.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            vm.activityPhase,
            .modelLoading(progress: 0.0),
            "A non-LoadProgressReporting backend must keep activityPhase at progress 0.0 throughout"
        )

        await backend.releaseLoadSuccess()
        await loadTask.value

        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertTrue(vm.isModelLoaded)
    }

    // MARK: - Failure path

    func test_activityPhase_resetsToIdle_onLoadFailure() async throws {
        let backend = ProgressBridgeBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let vm = ChatViewModel(inferenceService: service)
        vm.progressBridgePollInterval = .milliseconds(2)
        vm.selectedModel = makeModelInfo()

        let loadTask = Task { await vm.loadSelectedModel() }
        await backend.waitUntilLoadStarted()

        await backend.fireProgress(0.5)
        await waitForPhase(.modelLoading(progress: 0.5), on: vm)

        await backend.releaseLoadFailure(BridgeTestError.plannedFailure)
        await loadTask.value

        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertFalse(vm.isModelLoaded)
        XCTAssertNotNil(vm.errorMessage)
    }
}

// MARK: - Test backends

private enum BridgeTestError: Error, Sendable {
    case plannedFailure
}

private actor BridgeGate {
    enum Release: Sendable {
        case success
        case failure(any Error & Sendable)
    }

    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseDecision: Release?
    private var releaseWaiters: [CheckedContinuation<Release, Never>] = []

    func markStarted() {
        didStart = true
        for w in startWaiters { w.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async -> Release {
        if let releaseDecision { return releaseDecision }
        return await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func releaseSuccess() { release(.success) }
    func releaseFailure(_ error: any Error & Sendable) { release(.failure(error)) }

    private func release(_ decision: Release) {
        guard releaseDecision == nil else { return }
        releaseDecision = decision
        for w in releaseWaiters { w.resume(returning: decision) }
        releaseWaiters.removeAll()
    }
}

/// Test backend that adopts `LoadProgressReporting` and exposes a manual progress hook.
private final class ProgressBridgeBackend: InferenceBackend,
                                           LoadProgressReporting,
                                           @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private let lock = NSLock()
    private var handler: (@Sendable (Double) async -> Void)?

    private let gate = BridgeGate()

    func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fireProgress(_ value: Double) async {
        let h = lock.withLock { handler }
        await h?(value)
    }

    func waitUntilLoadStarted() async { await gate.waitUntilStarted() }
    func releaseLoadSuccess() async { await gate.releaseSuccess() }
    func releaseLoadFailure(_ error: any Error & Sendable) async { await gate.releaseFailure(error) }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        await gate.markStarted()
        switch await gate.waitForRelease() {
        case .success: isModelLoaded = true
        case .failure(let error): throw error
        }
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}

/// Test backend that does NOT adopt `LoadProgressReporting`.
private final class PlainBridgeBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private let gate = BridgeGate()

    func waitUntilLoadStarted() async { await gate.waitUntilStarted() }
    func releaseLoadSuccess() async { await gate.releaseSuccess() }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        await gate.markStarted()
        switch await gate.waitForRelease() {
        case .success: isModelLoaded = true
        case .failure(let error): throw error
        }
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}

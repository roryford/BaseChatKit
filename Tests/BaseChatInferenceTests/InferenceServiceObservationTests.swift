import XCTest
import Observation
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests that `@Observable` property changes on `InferenceService` trigger
/// observation tracking.
///
/// Written **before** the decomposition (#279) so that if the extraction breaks
/// observation propagation through the facade's computed properties, these tests
/// fail immediately.
@MainActor
final class InferenceServiceObservationTests: XCTestCase {

    // MARK: - isModelLoaded

    func test_isModelLoaded_triggersObservation_onLoad() async throws {
        let mock = MockInferenceBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? mock : nil }

        let changed = expectation(description: "isModelLoaded observed")
        withObservationTracking {
            _ = service.isModelLoaded
        } onChange: {
            changed.fulfill()
        }

        try await service.loadModel(from: makeModelInfo())
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertTrue(service.isModelLoaded)
    }

    func test_isModelLoaded_triggersObservation_onUnload() {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "Mock")
        XCTAssertTrue(service.isModelLoaded)

        let changed = expectation(description: "isModelLoaded observed")
        withObservationTracking {
            _ = service.isModelLoaded
        } onChange: {
            changed.fulfill()
        }

        service.unloadModel()
        wait(for: [changed], timeout: 2)
        XCTAssertFalse(service.isModelLoaded)
    }

    // MARK: - isGenerating

    func test_isGenerating_triggersObservation_onEnqueue() throws {
        let mock = GatedBackend()
        let service = InferenceService(backend: mock, name: "Mock")

        let changed = expectation(description: "isGenerating observed")
        withObservationTracking {
            _ = service.isGenerating
        } onChange: {
            changed.fulfill()
        }

        _ = try service.enqueue(messages: [("user", "hi")])
        wait(for: [changed], timeout: 2)
        XCTAssertTrue(service.isGenerating)
    }

    // MARK: - activeBackendName

    func test_activeBackendName_triggersObservation_onLoad() async throws {
        let mock = MockInferenceBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? mock : nil }

        let changed = expectation(description: "activeBackendName observed")
        withObservationTracking {
            _ = service.activeBackendName
        } onChange: {
            changed.fulfill()
        }

        try await service.loadModel(from: makeModelInfo())
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertNotNil(service.activeBackendName)
    }

    // MARK: - modelLoadProgress

    func test_modelLoadProgress_triggersObservation_onLoadStart() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let changed = expectation(description: "modelLoadProgress observed")
        withObservationTracking {
            _ = service.modelLoadProgress
        } onChange: {
            changed.fulfill()
        }

        let loadTask = Task { try await service.loadModel(from: makeModelInfo()) }
        await backend.waitUntilLoadStarted()

        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(service.modelLoadProgress, 0.0)

        await backend.releaseLoad()
        try await loadTask.value
    }

    func test_modelLoadProgress_triggersObservation_onComplete() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let loadTask = Task { try await service.loadModel(from: makeModelInfo()) }
        await backend.waitUntilLoadStarted()

        // Now modelLoadProgress is 0.0 — observe the transition to nil on completion.
        XCTAssertEqual(service.modelLoadProgress, 0.0)

        let changed = expectation(description: "modelLoadProgress nil on complete")
        withObservationTracking {
            _ = service.modelLoadProgress
        } onChange: {
            changed.fulfill()
        }

        await backend.releaseLoad()
        try await loadTask.value

        await fulfillment(of: [changed], timeout: 2)
        XCTAssertNil(service.modelLoadProgress)
    }

    // MARK: - Helpers

    private func makeModelInfo() -> ModelInfo {
        ModelInfo(
            name: "Test",
            fileName: "Test.bin",
            url: URL(fileURLWithPath: "/Test.bin"),
            fileSize: 0,
            modelType: .gguf
        )
    }
}

// MARK: - Test Backends

/// Blocks generation until explicitly released, for observing isGenerating transitions.
private final class GatedBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private var activeContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        isGenerating = true
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
            self?.activeContinuation = continuation
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {
        isGenerating = false
        activeContinuation?.finish()
        activeContinuation = nil
    }

    func unloadModel() {
        isModelLoaded = false
        activeContinuation?.finish()
        activeContinuation = nil
    }
}

/// Blocks loadModel until explicitly released, for observing modelLoadProgress transitions.
private final class GatedLoadBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = false
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private let gate = LoadGate()

    func waitUntilLoadStarted() async { await gate.waitUntilStarted() }
    func releaseLoad() async { await gate.release() }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        await gate.markStarted()
        await gate.waitForRelease()
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}

/// Simple actor-based gate for controlling when loadModel completes.
private actor LoadGate {
    private var started = false
    private var released = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }
}

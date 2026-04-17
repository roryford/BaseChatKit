import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Verifies that `InferenceService.denyPolicy` — the three-way policy applied when a
/// `ModelLoadPlan` returns a `.deny` verdict — correctly governs the deny path.
///
/// Tests build a plan explicitly via `ModelLoadPlan.compute` with a controlled
/// `Environment` and pass it to `loadModel(from:plan:)` so the test fixtures do not
/// depend on real-device memory.
final class LoadDenyPolicyInferenceServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeModel() -> ModelInfo {
        ModelInfo(
            name: "test-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 4_000_000_000,  // 4 GB, way over the 500 MB fake environment
            modelType: .gguf
        )
    }

    private func makeDenyingPlan(for model: ModelInfo) -> ModelLoadPlan {
        let environment = ModelLoadPlan.Environment(
            availableMemoryBytes: { 500_000_000 },       // 500 MB available
            physicalMemoryBytes: 8_000_000_000
        )
        let plan = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 2048,
            strategy: .resident,
            environment: environment
        )
        // Precondition: fixture must produce a .deny verdict or the test is meaningless.
        XCTAssertEqual(plan.verdict, .deny,
                       "Fixture must produce a .deny plan; got \(plan.verdict)")
        return plan
    }

    @MainActor
    private func makeService() -> InferenceService {
        let service = InferenceService()
        service.registerBackendFactory { _ in
            let caps = BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: 2048,
                requiresPromptTemplate: false,
                supportsSystemPrompt: true,
                supportsToolCalling: false,
                supportsStructuredOutput: false,
                cancellationStyle: .cooperative,
                supportsTokenCounting: false,
                memoryStrategy: .resident
            )
            return MockInferenceBackend(capabilities: caps)
        }
        return service
    }

    // MARK: - throwError policy throws on deny plan

    @MainActor
    func test_throwErrorPolicy_denyPlanThrows_memoryInsufficient() async {
        let service = makeService()
        service.denyPolicy = .throwError

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        do {
            try await service.loadModel(from: model, plan: plan)
            XCTFail("Expected memoryInsufficient error")
        } catch let error as InferenceError {
            guard case .memoryInsufficient(let required, let available) = error else {
                XCTFail("Expected memoryInsufficient, got \(error)")
                return
            }
            // `required` is the plan's total (resident + KV), not just the file size.
            XCTAssertGreaterThanOrEqual(required, 4_000_000_000)
            XCTAssertEqual(available, 500_000_000)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertFalse(service.isModelLoaded)
    }

    // MARK: - warnOnly policy proceeds

    @MainActor
    func test_warnOnlyPolicy_denyPlanLogs_doesNotThrow() async throws {
        let service = makeService()
        service.denyPolicy = .warnOnly

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        try await service.loadModel(from: model, plan: plan)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - custom policy sees plan

    @MainActor
    func test_customPolicy_denyPlanInvokesHandler() async throws {
        let service = makeService()

        let capturedVerdict = LockedValue<ModelLoadPlan.Verdict?>(nil)
        service.denyPolicy = .custom { plan in
            capturedVerdict.set(plan.verdict)
            // Proceed.
        }

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        try await service.loadModel(from: model, plan: plan)
        XCTAssertEqual(capturedVerdict.get(), .deny)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - custom policy may reject by throwing

    @MainActor
    func test_customPolicy_canThrowToReject() async {
        let service = makeService()

        struct CustomRejection: Error, Equatable {}
        service.denyPolicy = .custom { _ in throw CustomRejection() }

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        do {
            try await service.loadModel(from: model, plan: plan)
            XCTFail("Expected CustomRejection")
        } catch is CustomRejection {
            // success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(service.isModelLoaded)
    }
}

// MARK: - Test helpers

/// Simple thread-safe box for capturing values inside @Sendable closures.
private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func set(_ new: T) { lock.lock(); defer { lock.unlock() }; value = new }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Verifies that `InferenceService.denyPolicy` — the three-way replacement for
/// `MemoryGate.DenyBehavior` — correctly governs the `.deny` verdict path.
///
/// These tests still install a `MemoryGate` to control the plan's
/// `availableMemoryBytes` environment; the knob under test is `denyPolicy`.
/// Stage 5 will remove the gate in favour of a direct environment injection.
final class MemoryGateInferenceServiceTests: XCTestCase {

    // MARK: - Deny + throwError throws memoryInsufficient

    @MainActor
    func test_denyWithThrowError_throwsMemoryInsufficient() async {
        let service = InferenceService()
        service.registerBackendFactory { modelType in
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

        // Gate supplies the plan's available-memory environment; denyPolicy controls behaviour.
        service.memoryGate = MemoryGate(
            availableMemoryBytes: { 500_000_000 },  // 500 MB
            physicalMemoryBytes: 8_000_000_000
        )
        service.denyPolicy = .throwError

        let modelInfo = ModelInfo(
            name: "test-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 4_000_000_000,  // 4 GB raw size, way over 500 MB
            modelType: .gguf
        )

        do {
            try await service.loadModel(from: modelInfo, contextSize: 2048)
            XCTFail("Expected memoryInsufficient error")
        } catch let error as InferenceError {
            if case .memoryInsufficient(let required, let available) = error {
                // Post-ModelLoadPlan: the `required` value is the plan's total estimated
                // footprint (resident + KV), not just the raw file size. For a resident
                // strategy with no architectural KV hint, the total is fileSize + an
                // estimate based on the legacy fallback KV bytes-per-token.
                XCTAssertGreaterThanOrEqual(required, 4_000_000_000,
                                            "required must at least cover the model file size")
                XCTAssertEqual(available, 500_000_000)
            } else {
                XCTFail("Expected memoryInsufficient, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Deny + warnOnly proceeds without error

    @MainActor
    func test_denyWithWarnOnly_proceedsWithoutError() async throws {
        let service = InferenceService()
        service.registerBackendFactory { _ in
            MockInferenceBackend()
        }

        service.memoryGate = MemoryGate(
            availableMemoryBytes: { 500_000_000 },
            physicalMemoryBytes: 8_000_000_000
        )
        service.denyPolicy = .warnOnly

        let modelInfo = ModelInfo(
            name: "test-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 4_000_000_000,
            modelType: .gguf
        )

        // Should not throw -- warnOnly logs but proceeds.
        try await service.loadModel(from: modelInfo, contextSize: 2048)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - Deny + custom policy receives plan

    @MainActor
    func test_denyWithCustomPolicy_receivesPlanAndCanProceed() async throws {
        let service = InferenceService()
        service.registerBackendFactory { _ in
            MockInferenceBackend()
        }

        service.memoryGate = MemoryGate(
            availableMemoryBytes: { 500_000_000 },
            physicalMemoryBytes: 8_000_000_000
        )

        let capturedVerdict = LockedValue<ModelLoadPlan.Verdict?>(nil)
        service.denyPolicy = .custom { plan in
            capturedVerdict.set(plan.verdict)
            // Proceed (do not throw).
        }

        let modelInfo = ModelInfo(
            name: "test-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 4_000_000_000,
            modelType: .gguf
        )

        try await service.loadModel(from: modelInfo, contextSize: 2048)
        XCTAssertEqual(capturedVerdict.get(), .deny)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - Deny + custom policy can reject

    @MainActor
    func test_denyWithCustomPolicy_canThrowToReject() async {
        let service = InferenceService()
        service.registerBackendFactory { _ in
            MockInferenceBackend()
        }

        service.memoryGate = MemoryGate(
            availableMemoryBytes: { 500_000_000 },
            physicalMemoryBytes: 8_000_000_000
        )

        struct CustomRejection: Error, Equatable {}
        service.denyPolicy = .custom { _ in
            throw CustomRejection()
        }

        let modelInfo = ModelInfo(
            name: "test-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 4_000_000_000,
            modelType: .gguf
        )

        do {
            try await service.loadModel(from: modelInfo, contextSize: 2048)
            XCTFail("Expected CustomRejection")
        } catch is CustomRejection {
            // success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(service.isModelLoaded)
    }

    // MARK: - External strategy skips check entirely

    @MainActor
    func test_externalStrategy_skipsMemoryCheck() async throws {
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
                memoryStrategy: .external
            )
            return MockInferenceBackend(capabilities: caps)
        }

        // Even with throwError + tiny memory, external should always allow.
        service.memoryGate = MemoryGate(
            availableMemoryBytes: { 1024 },
            physicalMemoryBytes: 1024
        )
        service.denyPolicy = .throwError

        let modelInfo = ModelInfo(
            name: "test-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 999_999_999_999,
            modelType: .gguf
        )

        try await service.loadModel(from: modelInfo, contextSize: 2048)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - No gate set (backward compatibility)

    @MainActor
    func test_noGateSet_proceedsNormally() async throws {
        let service = InferenceService()
        service.registerBackendFactory { _ in
            MockInferenceBackend()
        }

        // No memoryGate set -- should proceed without any check.
        XCTAssertNil(service.memoryGate)

        let modelInfo = ModelInfo(
            name: "test-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 4_000_000_000,
            modelType: .gguf
        )

        try await service.loadModel(from: modelInfo, contextSize: 2048)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - Allow verdict proceeds

    @MainActor
    func test_allowVerdict_proceedsNormally() async throws {
        let service = InferenceService()
        service.registerBackendFactory { _ in
            MockInferenceBackend()
        }

        service.memoryGate = MemoryGate(
            availableMemoryBytes: { 16_000_000_000 },
            physicalMemoryBytes: 32_000_000_000
        )
        service.denyPolicy = .throwError

        let modelInfo = ModelInfo(
            name: "small-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 1_000_000_000,  // 1 GB raw size, fits in 16 GB
            modelType: .gguf
        )

        try await service.loadModel(from: modelInfo, contextSize: 2048)
        XCTAssertTrue(service.isModelLoaded)
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

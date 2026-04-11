import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

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

        // Gate with very little available memory and throwError behavior.
        service.memoryGate = MemoryGate(
            availableMemoryBytes: { 500_000_000 },  // 500 MB
            physicalMemoryBytes: 8_000_000_000,
            denyBehavior: .throwError
        )

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
                XCTAssertEqual(required, 4_000_000_000)
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
            physicalMemoryBytes: 8_000_000_000,
            denyBehavior: .warnOnly
        )

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
            physicalMemoryBytes: 1024,
            denyBehavior: .throwError
        )

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
            physicalMemoryBytes: 32_000_000_000,
            denyBehavior: .throwError
        )

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

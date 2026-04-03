import XCTest
import BaseChatCore
import BaseChatTestSupport

/// Runs the shared `stopGeneration()` contract tests against MockInferenceBackend.
final class StopGenerationContractMockTests: XCTestCase {

    func test_mockBackend_honoursStopGenerationContract() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["one", "two", "three"]

        try await StopGenerationContractTests.verifyStopLeavesBackendReusable(backend)
    }

    func test_stopGeneration_whenIdle_isNoOp() {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true

        // Stopping with no generation in progress must not crash or corrupt state.
        backend.stopGeneration()

        XCTAssertFalse(backend.isGenerating)
        XCTAssertTrue(backend.isModelLoaded)
        XCTAssertEqual(backend.stopCallCount, 1)
    }
}

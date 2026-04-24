import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Default-behavior guard for issue #683: callers that don't pass `grammar:`
/// must observe `GenerationConfig.grammar == nil` at the backend, so existing
/// non-grammar workloads stay unaffected by the new parameter.
@MainActor
final class EnqueueGrammarDefaultNilTests: XCTestCase {

    func test_enqueue_withoutGrammar_leavesConfigGrammarNil() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["x"]
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")]
        )

        for try await _ in stream.events {}

        XCTAssertNil(
            backend.lastConfig?.grammar,
            "Default enqueue must not set GenerationConfig.grammar — backends rely on nil to skip grammar sampling."
        )
    }
}

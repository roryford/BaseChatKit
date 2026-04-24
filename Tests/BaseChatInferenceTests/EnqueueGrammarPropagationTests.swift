import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

@MainActor
final class EnqueueGrammarPropagationTests: XCTestCase {

    func test_enqueue_withGrammar_forwardsToBackendConfig() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["x"]
        let service = InferenceService(backend: backend, name: "Mock")

        let grammar = "root ::= \"x\""
        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")],
            grammar: grammar
        )

        for try await _ in stream.events {}

        XCTAssertEqual(
            backend.lastConfig?.grammar,
            grammar,
            "grammar passed to enqueue must reach the backend via GenerationConfig.grammar"
        )
    }
}

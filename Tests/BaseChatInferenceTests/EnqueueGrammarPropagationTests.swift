import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Verifies that `InferenceService.enqueue(..., grammar:)` forwards the GBNF
/// string all the way to `InferenceBackend.generate(request:)` via
/// `GenerationConfig.grammar`.
///
/// Issue #683 — closes the gap left by #664 (config field) and #667 (Llama
/// sampler wiring): until this PR, no caller could set `grammar` because the
/// public enqueue surface omitted the parameter and the coordinator never
/// assigned it onto its inline `GenerationConfig`.
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

        // Drain the stream so generate() runs and populates lastConfig.
        for try await _ in stream.events {}

        XCTAssertEqual(
            backend.lastConfig?.grammar,
            grammar,
            "grammar passed to enqueue must reach the backend via GenerationConfig.grammar"
        )
    }
}

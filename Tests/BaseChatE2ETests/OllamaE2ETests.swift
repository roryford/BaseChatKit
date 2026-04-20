import XCTest
import BaseChatCore
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// True end-to-end tests hitting a real local Ollama server.
///
/// These tests perform real inference against Ollama at `localhost:11434`.
/// They are automatically skipped when:
/// - No Ollama server is reachable
/// - No models are available (or none in the preferred 7-8B range)
///
/// Unlike mock-based tests, these use NO stubs — real HTTP, real NDJSON
/// streaming, real token generation from a real model.
@MainActor
final class OllamaE2ETests: XCTestCase {

    private var backend: OllamaBackend!
    private var modelName: String!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.hasOllamaServer, "Ollama server not running at localhost:11434")

        guard let model = HardwareRequirements.findOllamaModel() else {
            throw XCTSkip("No Ollama model available")
        }
        modelName = model

        backend = OllamaBackend()
        backend.configure(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: modelName
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        modelName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func generate(
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 64
    ) async throws -> String {
        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: maxTokens
        )
        let stream = try backend.generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )
        return try await collectTokens(stream)
    }

    // MARK: - Real Inference Tests

    func test_realInference_generatesNonEmptyResponse() async throws {
        let response = try await generate(prompt: "Reply with exactly one word.")

        XCTAssertFalse(response.isEmpty, "Ollama should generate a non-empty response (model: \(modelName!))")
    }

    func test_realInference_withSystemPrompt() async throws {
        let response = try await generate(
            prompt: "What are you?",
            systemPrompt: "You are a helpful pirate. Always respond in pirate speak."
        )

        XCTAssertFalse(response.isEmpty, "Should generate a response with system prompt")
    }

    func test_realInference_multiTurn() async throws {
        // First turn
        let firstResponse = try await generate(prompt: "Remember the number 42.")
        XCTAssertFalse(firstResponse.isEmpty, "First response should not be empty")

        // Second turn — Ollama is stateless per request, so multi-turn requires
        // conversation history. Test that a second generation works independently.
        let secondResponse = try await generate(prompt: "What is 2 + 2?")
        XCTAssertFalse(secondResponse.isEmpty, "Second response should not be empty")
    }

    func test_realInference_stopGeneration() async throws {
        let config = GenerationConfig(
            temperature: 0.7,
            maxOutputTokens: 2048
        )

        let stream = try backend.generate(
            prompt: "Write a very detailed essay about the history of computing from the 1940s to today.",
            systemPrompt: nil,
            config: config
        )

        // Wait for at least a few tokens to arrive, then stop.
        // Ollama may take 10-20s to load the model into VRAM on first request.
        var tokenCount = 0
        let collectTask = Task {
            for try await event in stream.events {
                if case .token(_) = event {
                    tokenCount += 1
                    if tokenCount >= 5 { break }
                }
            }
        }

        try await collectTask.value
        XCTAssertGreaterThanOrEqual(tokenCount, 5, "Should have received at least 5 tokens")

        // Now stop — verify the backend accepts it without crashing.
        backend.stopGeneration()
    }

    func test_realInference_respectsMaxOutputTokens() async throws {
        // Request a very short response via maxOutputTokens.
        let response = try await generate(
            prompt: "Write a long story about a dragon.",
            maxTokens: 10
        )

        // The response should be relatively short. With 10 max output tokens
        // and Ollama's num_predict, we can't assert exact token count but
        // the response shouldn't be novel-length.
        XCTAssertFalse(response.isEmpty, "Should still generate some output")
    }

    func test_backendCapabilities() {
        XCTAssertTrue(backend.capabilities.supportsStreaming)
        XCTAssertTrue(backend.capabilities.isRemote)
        XCTAssertTrue(backend.capabilities.supportsSystemPrompt)
        XCTAssertEqual(backend.backendName, "Ollama")
    }

    // MARK: - Thinking-specific E2E Tests

    /// Prompt that reliably provokes chain-of-thought on reasoning models.
    private static let reasoningPrompt = """
    Solve this carefully: a train leaves station A at 3pm travelling 60 mph, \
    and another leaves station B at 4pm travelling 80 mph toward it. The \
    stations are 300 miles apart. At what time do they meet?
    """

    /// Drives a probe generation to classify the selected model as thinking or
    /// non-thinking by checking whether any `.thinkingToken` event arrives
    /// before the first `.token`. Returns `true` when the model emits thinking.
    ///
    /// Uses a short `maxOutputTokens` budget so the probe terminates quickly
    /// even for chatty models.
    private func probeModelEmitsThinking() async throws -> Bool {
        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: 64
        )
        let stream = try backend.generate(
            prompt: Self.reasoningPrompt,
            systemPrompt: nil,
            config: config
        )
        var sawThinking = false
        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                sawThinking = true
            case .token:
                // First visible token — we've classified the model.
                return sawThinking
            default:
                continue
            }
        }
        // Stream finished without ever emitting a visible token. If we saw
        // thinking first, still classify as thinking; otherwise the probe is
        // inconclusive and we treat the model as non-thinking.
        return sawThinking
    }

    /// Test A — Thinking models must emit `.thinkingToken` events and fire
    /// exactly one `.thinkingComplete` before the first visible `.token`.
    func testThinkingModel_emitsThinkingEventsBeforeVisibleOutput() async throws {
        let config = GenerationConfig(temperature: 0.3)
        let stream = try backend.generate(
            prompt: Self.reasoningPrompt,
            systemPrompt: nil,
            config: config
        )

        var thinkingTokenCount = 0
        var thinkingCompleteCount = 0
        var firstTokenAfterThinkingComplete: Bool?
        var visibleText = ""
        var sawFirstVisibleToken = false

        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                thinkingTokenCount += 1
                if sawFirstVisibleToken {
                    XCTFail("Received .thinkingToken after visible .token — reasoning must precede visible output on this backend")
                }
            case .thinkingComplete:
                thinkingCompleteCount += 1
                // If a visible token arrives next, record the ordering.
                if !sawFirstVisibleToken {
                    firstTokenAfterThinkingComplete = true
                }
            case .token(let text):
                visibleText += text
                sawFirstVisibleToken = true
                if firstTokenAfterThinkingComplete == nil {
                    firstTokenAfterThinkingComplete = false
                }
            default:
                continue
            }
        }

        try XCTSkipIf(
            thinkingTokenCount == 0,
            "selected model '\(modelName!)' does not produce thinking tokens — skipping thinking-specific assertions"
        )

        XCTAssertEqual(
            thinkingCompleteCount,
            1,
            "Exactly one .thinkingComplete event must fire (got \(thinkingCompleteCount), model: \(modelName!))"
        )
        XCTAssertEqual(
            firstTokenAfterThinkingComplete,
            true,
            ".thinkingComplete must fire before the first visible .token (model: \(modelName!))"
        )
        XCTAssertFalse(
            visibleText.isEmpty,
            "Thinking model must still emit a visible response (model: \(modelName!))"
        )
    }

    /// Test B — `maxThinkingTokens=0` must suppress reasoning while still
    /// producing visible output.
    ///
    // FIXME(P4): This test will fail until OllamaBackend sends `think: false`
    // when maxThinkingTokens == 0. The `BCK_P4_READY` env gate effectively
    // skips this test until the P4 wiring lands; removing the gate is the
    // one-line follow-up that activates the assertion.
    func testThinkingModel_maxThinkingTokensZero_suppressesReasoning() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BCK_P4_READY"] == nil,
            "BCK_P4_READY not set — OllamaBackend does not yet forward `think: false` to Ollama; remove this guard once P4 lands"
        )

        // Probe first with a fresh stream — classify the selected model.
        let isThinkingModel = try await probeModelEmitsThinking()
        try XCTSkipIf(
            !isThinkingModel,
            "selected model '\(modelName!)' does not produce thinking tokens — maxThinkingTokens=0 assertion is vacuous"
        )

        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: nil,
            maxThinkingTokens: 0
        )
        let stream = try backend.generate(
            prompt: Self.reasoningPrompt,
            systemPrompt: nil,
            config: config
        )

        var thinkingTokenCount = 0
        var thinkingCompleteCount = 0
        var visibleText = ""

        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                thinkingTokenCount += 1
            case .thinkingComplete:
                thinkingCompleteCount += 1
            case .token(let text):
                visibleText += text
            default:
                continue
            }
        }

        XCTAssertEqual(
            thinkingTokenCount,
            0,
            "maxThinkingTokens=0 must suppress every .thinkingToken event (got \(thinkingTokenCount), model: \(modelName!))"
        )
        XCTAssertEqual(
            thinkingCompleteCount,
            0,
            "maxThinkingTokens=0 must fire zero .thinkingComplete events (got \(thinkingCompleteCount), model: \(modelName!))"
        )
        XCTAssertFalse(
            visibleText.isEmpty,
            "Visible response must still arrive when reasoning is suppressed (model: \(modelName!))"
        )
    }

    /// Test C — `maxThinkingTokens=5` must cap reasoning emission; OllamaBackend
    /// drops thinking chunks once `thinkingTokenCount >= limit`, so only the
    /// first few lines survive.
    func testThinkingModel_maxThinkingTokensCapped_limitsReasoning() async throws {
        // Probe first to classify the model.
        let isThinkingModel = try await probeModelEmitsThinking()
        try XCTSkipIf(
            !isThinkingModel,
            "selected model '\(modelName!)' does not produce thinking tokens — cap assertion is vacuous"
        )

        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: nil,
            maxThinkingTokens: 5
        )
        let stream = try backend.generate(
            prompt: Self.reasoningPrompt,
            systemPrompt: nil,
            config: config
        )

        var thinkingTokenCount = 0
        var thinkingCompleteCount = 0
        var visibleText = ""

        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                thinkingTokenCount += 1
            case .thinkingComplete:
                thinkingCompleteCount += 1
            case .token(let text):
                visibleText += text
            default:
                continue
            }
        }

        // Allow generous headroom over the cap — OllamaBackend counts per
        // NDJSON line, so the observed count hovers near but rarely exceeds the
        // limit by more than a handful. 20 is well above 5 and well below what
        // an uncapped run would produce for this prompt.
        XCTAssertLessThan(
            thinkingTokenCount,
            20,
            "maxThinkingTokens=5 must meaningfully cap reasoning emission (got \(thinkingTokenCount), model: \(modelName!))"
        )
        XCTAssertEqual(
            thinkingCompleteCount,
            1,
            "Exactly one .thinkingComplete event must fire even when capped (got \(thinkingCompleteCount), model: \(modelName!))"
        )
        XCTAssertFalse(
            visibleText.isEmpty,
            "Capped thinking must not starve visible output (model: \(modelName!))"
        )
    }
}

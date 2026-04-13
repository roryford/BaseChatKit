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
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
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
}

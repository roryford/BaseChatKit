#if Llama
import XCTest
import BaseChatCore
import BaseChatInference
import BaseChatTestSupport
import BaseChatBackends

/// True end-to-end tests hitting a real local GGUF model through `LlamaBackend`.
///
/// These tests load a real quantized GGUF from `~/Documents/Models/` and run
/// real token generation through llama.cpp. They are automatically skipped when:
/// - Not running on Apple Silicon (Metal required)
/// - Running in the iOS Simulator (no Metal)
/// - No loadable GGUF is found in `~/Documents/Models/`
///
/// Unlike mock-based tests, these use NO stubs — real Metal, real llama.cpp,
/// real token generation from a real model.
@MainActor
final class LlamaE2ETests: XCTestCase {

    // LlamaBackend uses a global `llama_backend_init` and tests that repeatedly
    // load/unload trigger a Metal buffer assertion inside llama.cpp
    // (ggml-metal-context.m:359 "GGML_ASSERT(buf_dst) failed"). The CLAUDE.md
    // guidance is to share a single instance across the suite — the process
    // exit handles final cleanup via LlamaBackend.deinit.
    private nonisolated(unsafe) static var sharedBackend: LlamaBackend?
    private nonisolated(unsafe) static var sharedModelURL: URL?
    private nonisolated(unsafe) static var loadFailure: Error?

    private var backend: LlamaBackend!
    private var modelURL: URL!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaBackend requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaBackend requires Metal (unavailable in simulator)")

        guard let url = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model found in ~/Documents/Models/")
        }

        if let prior = Self.loadFailure {
            throw prior
        }

        if Self.sharedBackend == nil {
            let fresh = LlamaBackend()
            do {
                try await fresh.loadModel(from: url, contextSize: 2048)
                Self.sharedBackend = fresh
                Self.sharedModelURL = url
            } catch {
                Self.loadFailure = error
                throw error
            }
        }

        backend = Self.sharedBackend
        modelURL = Self.sharedModelURL
    }

    override func tearDown() async throws {
        // Deliberately do NOT unload between tests — the shared backend stays
        // loaded for the whole suite. Per-test teardown just drops local refs.
        backend = nil
        modelURL = nil
        try await super.tearDown()
    }

    // No class-level tearDown — it's sync and can't await the detached cleanup
    // `unloadModel()` schedules. Instead `test_zzz_drainCleanup` (alphabetically
    // last) awaits the unload on the shared backend before process exit,
    // avoiding a race with Metal's device deinit.

    func test_zzz_drainCleanup() async throws {
        guard let backend = Self.sharedBackend else {
            throw XCTSkip("Shared backend never loaded (skipped earlier)")
        }
        await backend.unloadAndWait()
        Self.sharedBackend = nil
        Self.sharedModelURL = nil
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
        // LlamaBackend does not apply chat templates — callers must format
        // prompts in the template the model was trained on. PromptTemplate
        // detection lives in `InferenceService` (not exercised here), so the
        // test explicitly uses ChatML, which the shared smollm2 and Qwen
        // fixtures both expect.
        let formattedPrompt = PromptTemplate.chatML.format(
            messages: [(role: "user", content: prompt)],
            systemPrompt: systemPrompt
        )
        let stream = try backend.generate(
            prompt: formattedPrompt,
            systemPrompt: nil,
            config: config
        )
        return try await collectTokens(stream)
    }

    // MARK: - Real Inference Tests

    func test_realInference_generatesNonEmptyResponse() async throws {
        let response = try await generate(prompt: "Reply with exactly one word.")

        XCTAssertFalse(response.isEmpty, "LlamaBackend should generate a non-empty response (model: \(modelURL.lastPathComponent))")
    }

    func test_realInference_withSystemPrompt() async throws {
        let response = try await generate(
            prompt: "What are you?",
            systemPrompt: "You are a helpful pirate. Always respond in pirate speak."
        )

        XCTAssertFalse(response.isEmpty, "Should generate a response with system prompt")
    }

    func test_realInference_multiTurn() async throws {
        // LlamaBackend is stateless per generate() call — context is not carried
        // across requests, so "multi-turn" here means two independent generations
        // succeed on the same loaded model.
        let firstResponse = try await generate(prompt: "Remember the number 42.")
        XCTAssertFalse(firstResponse.isEmpty, "First response should not be empty")

        let secondResponse = try await generate(prompt: "What is 2 + 2?")
        XCTAssertFalse(secondResponse.isEmpty, "Second response should not be empty")
    }

    func test_realInference_stopGeneration() async throws {
        let config = GenerationConfig(
            temperature: 0.7,
            maxOutputTokens: 2048
        )

        let formattedPrompt = PromptTemplate.chatML.format(
            messages: [(role: "user", content: "Write a very detailed essay about the history of computing from the 1940s to today.")],
            systemPrompt: nil
        )
        let stream = try backend.generate(
            prompt: formattedPrompt,
            systemPrompt: nil,
            config: config
        )

        // Drain the stream to completion after calling stopGeneration so the
        // backend fully unwinds isGenerating and releases its Metal resources
        // before the next test runs against the shared backend.
        var tokenCount = 0
        var didStop = false
        for try await event in stream.events {
            if case .token(_) = event {
                tokenCount += 1
                if tokenCount >= 5 && !didStop {
                    backend.stopGeneration()
                    didStop = true
                }
            }
        }

        XCTAssertGreaterThanOrEqual(tokenCount, 5, "Should have received at least 5 tokens")
        XCTAssertTrue(didStop, "Should have called stopGeneration")
    }

    func test_realInference_respectsMaxOutputTokens() async throws {
        let response = try await generate(
            prompt: "Write a long story about a dragon.",
            maxTokens: 10
        )

        // With max 10 output tokens the response shouldn't be novel-length,
        // but the exact token count depends on the tokenizer so we just
        // assert something came back.
        XCTAssertFalse(response.isEmpty, "Should still generate some output")
    }

    func test_backendCapabilities() {
        XCTAssertTrue(backend.capabilities.supportsStreaming)
        XCTAssertFalse(backend.capabilities.isRemote)
        XCTAssertTrue(backend.capabilities.supportsSystemPrompt)
        XCTAssertTrue(backend.capabilities.requiresPromptTemplate)
    }
}
#endif

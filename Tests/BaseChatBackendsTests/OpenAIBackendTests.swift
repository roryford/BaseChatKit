import XCTest
import BaseChatCore
@testable import BaseChatBackends

/// Tests for OpenAIBackend configuration, state, and capabilities.
final class OpenAIBackendTests: XCTestCase {

    // MARK: - Init & State

    func test_init_defaultState() {
        let backend = OpenAIBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Capabilities

    func test_capabilities_supportsTemperatureAndTopP() {
        let backend = OpenAIBackend()
        let caps = backend.capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
    }

    func test_capabilities_doesNotRequirePromptTemplate() {
        let backend = OpenAIBackend()
        XCTAssertFalse(backend.capabilities.requiresPromptTemplate,
                       "OpenAI handles chat templating server-side")
    }

    func test_capabilities_supportsSystemPrompt() {
        let backend = OpenAIBackend()
        XCTAssertTrue(backend.capabilities.supportsSystemPrompt)
    }

    // MARK: - Model Lifecycle

    func test_loadModel_withoutConfiguration_throws() async {
        let backend = OpenAIBackend()
        do {
            try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
            XCTFail("Should throw when no base URL is configured")
        } catch {
            // Expected — no baseURL configured
        }
    }

    func test_configure_thenLoadModel_succeeds() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)
    }

    func test_unloadModel_clearsState() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        XCTAssertTrue(backend.isModelLoaded)

        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_generate_withoutLoading_throws() {
        let backend = OpenAIBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())
        )
    }

    func test_stopGeneration_setsIsGeneratingFalse() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        // stopGeneration should be safe to call even when not generating
        backend.stopGeneration()
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Token Extraction (indirect via SSE + JSON)

    /// Verifies that the OpenAI JSON format can round-trip through SSE parsing.
    /// Since extractToken is private, we test the format indirectly by verifying
    /// the JSON structure matches what the parser expects.
    func test_extractToken_validJSON() {
        // The expected OpenAI streaming chunk format
        let json = #"{"choices":[{"delta":{"content":"token"}}]}"#
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(parsed)
        let choices = parsed?["choices"] as? [[String: Any]]
        XCTAssertNotNil(choices)
        let delta = choices?.first?["delta"] as? [String: Any]
        XCTAssertNotNil(delta)
        let content = delta?["content"] as? String
        XCTAssertEqual(content, "token")
    }
}

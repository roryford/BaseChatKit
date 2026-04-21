import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

final class GenerationConfigTests: XCTestCase {

    // MARK: - Default Values

    func test_defaultInit_temperature() {
        let config = GenerationConfig()
        XCTAssertEqual(config.temperature, 0.7, accuracy: 0.001)
    }

    func test_defaultInit_topP() {
        let config = GenerationConfig()
        XCTAssertEqual(config.topP, 0.9, accuracy: 0.001)
    }

    func test_defaultInit_repeatPenalty() {
        let config = GenerationConfig()
        XCTAssertEqual(config.repeatPenalty, 1.1, accuracy: 0.001)
    }

    func test_defaultInit_maxOutputTokens() {
        let config = GenerationConfig()
        XCTAssertEqual(config.maxOutputTokens, 2048)
    }

    func test_defaultInit_jsonMode() {
        let config = GenerationConfig()
        XCTAssertFalse(config.jsonMode)
    }

    // MARK: - Custom Init

    func test_customInit_propagatesAllValues() {
        let config = GenerationConfig(
            temperature: 1.2,
            topP: 0.95,
            repeatPenalty: 1.5,
            maxOutputTokens: 2048,
            jsonMode: true
        )

        XCTAssertEqual(config.temperature, 1.2, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(config.repeatPenalty, 1.5, accuracy: 0.001)
        XCTAssertEqual(config.maxOutputTokens, 2048)
        XCTAssertTrue(config.jsonMode)
    }

    func test_customInit_partialOverride() {
        let config = GenerationConfig(temperature: 0.0, maxOutputTokens: 1024)

        XCTAssertEqual(config.temperature, 0.0, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.9, accuracy: 0.001, "Non-overridden topP should use default")
        XCTAssertEqual(config.repeatPenalty, 1.1, accuracy: 0.001, "Non-overridden repeatPenalty should use default")
        XCTAssertEqual(config.maxOutputTokens, 1024, "maxOutputTokens should match provided value")
    }

    func test_customInit_maxOutputTokens_customValue() {
        let config = GenerationConfig(maxOutputTokens: 4096)
        XCTAssertEqual(config.maxOutputTokens, 4096)
    }

    func test_customInit_maxOutputTokens_nil() {
        let config = GenerationConfig(maxOutputTokens: nil)
        XCTAssertNil(config.maxOutputTokens)
    }

    func test_maxOutputTokens_isMutable() {
        var config = GenerationConfig()
        config.maxOutputTokens = 512
        XCTAssertEqual(config.maxOutputTokens, 512)
    }

    func test_jsonMode_isMutable() {
        var config = GenerationConfig()
        config.jsonMode = true
        XCTAssertTrue(config.jsonMode)
    }

    // MARK: - Mock Backend Captures maxOutputTokens

    func test_mockBackend_capturesMaxOutputTokens() async throws {
        let backend = MockInferenceBackend()
        try await backend.loadModel(from: URL(string: "file:///mock")!, plan: .testStub(effectiveContextSize: 512))

        let config = GenerationConfig(maxOutputTokens: 1024)
        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: config)
        for try await _ in stream.events {}

        XCTAssertEqual(backend.lastConfig?.maxOutputTokens, 1024)
    }
}

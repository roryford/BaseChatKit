import XCTest
@testable import BaseChatCore
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

    func test_defaultInit_maxTokens() {
        let config = GenerationConfig()
        XCTAssertEqual(config.maxTokens, 512)
    }

    func test_defaultInit_maxOutputTokens() {
        let config = GenerationConfig()
        XCTAssertEqual(config.maxOutputTokens, 2048)
    }

    // MARK: - Custom Init

    func test_customInit_propagatesAllValues() {
        let config = GenerationConfig(
            temperature: 1.2,
            topP: 0.95,
            repeatPenalty: 1.5,
            maxTokens: 2048
        )

        XCTAssertEqual(config.temperature, 1.2, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(config.repeatPenalty, 1.5, accuracy: 0.001)
        XCTAssertEqual(config.maxTokens, 2048)
    }

    func test_customInit_partialOverride() {
        let config = GenerationConfig(temperature: 0.0, maxTokens: 1024)

        XCTAssertEqual(config.temperature, 0.0, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.9, accuracy: 0.001, "Non-overridden topP should use default")
        XCTAssertEqual(config.repeatPenalty, 1.1, accuracy: 0.001, "Non-overridden repeatPenalty should use default")
        XCTAssertEqual(config.maxTokens, 1024)
        XCTAssertEqual(config.maxOutputTokens, 2048, "Non-overridden maxOutputTokens should use default")
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

    // MARK: - Mock Backend Captures maxOutputTokens

    func test_mockBackend_capturesMaxOutputTokens() async throws {
        let backend = MockInferenceBackend()
        try await backend.loadModel(from: URL(string: "file:///mock")!, contextSize: 512)

        let config = GenerationConfig(maxOutputTokens: 1024)
        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: config)
        for try await _ in stream.events {}

        XCTAssertEqual(backend.lastConfig?.maxOutputTokens, 1024)
    }
}

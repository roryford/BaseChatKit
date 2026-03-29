import XCTest
@testable import BaseChatCore

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
    }
}

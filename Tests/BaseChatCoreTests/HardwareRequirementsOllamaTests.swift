import XCTest
@testable import BaseChatTestSupport

final class HardwareRequirementsOllamaTests: XCTestCase {

    // MARK: - Helpers

    private func model(name: String, parameterSize: String) -> [String: Any] {
        ["name": name, "details": ["parameter_size": parameterSize]]
    }

    // MARK: - selectOllamaModel

    func test_picks7BModelFromMixedList() {
        let models = [
            model(name: "phi:3b", parameterSize: "3.0B"),
            model(name: "llama3:7b", parameterSize: "7.2B"),
            model(name: "llama3:13b", parameterSize: "13.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "llama3:7b")
    }

    func test_picks8BModel() {
        let models = [
            model(name: "llama3.1:8b", parameterSize: "8.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "llama3.1:8b")
    }

    func test_fallsBackToFirstWhenNoneInRange() {
        let models = [
            model(name: "tinyllama:1b", parameterSize: "1.0B"),
            model(name: "phi:3b", parameterSize: "3.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "tinyllama:1b")
    }

    func test_emptyModelList_returnsNil() {
        let result = HardwareRequirements.selectOllamaModel(from: [])
        XCTAssertNil(result)
    }

    func test_missingDetailsField_skippedAndFallsBack() {
        let models: [[String: Any]] = [
            ["name": "broken-model"],
            model(name: "fallback:7b", parameterSize: "7.2B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "fallback:7b")
    }

    func test_missingParameterSize_skippedAndFallsBack() {
        let models: [[String: Any]] = [
            ["name": "no-size", "details": ["family": "llama"]],
            model(name: "good:8b", parameterSize: "8.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "good:8b")
    }

    func test_customSizeRange() {
        let models = [
            model(name: "mistral:7b", parameterSize: "7.2B"),
            model(name: "llama3:13b", parameterSize: "13.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(
            from: models,
            preferredSizeRange: 12.0...14.0
        )
        XCTAssertEqual(result, "llama3:13b")
    }

    func test_unparseableParameterSize_skippedAndFallsBack() {
        let models: [[String: Any]] = [
            model(name: "weird:latest", parameterSize: "large"),
            model(name: "fallback:3b", parameterSize: "3.0B"),
        ]
        // Neither model is in the default 6.5...9.0 range, so falls back to first.
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "weird:latest")
    }

    func test_multipleModelsInRange_returnsFirst() {
        let models = [
            model(name: "mistral:7b", parameterSize: "7.2B"),
            model(name: "llama3.1:8b", parameterSize: "8.0B"),
        ]
        let result = HardwareRequirements.selectOllamaModel(from: models)
        XCTAssertEqual(result, "mistral:7b")
    }
}

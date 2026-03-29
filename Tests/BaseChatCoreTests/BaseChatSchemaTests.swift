import XCTest
import SwiftData
@testable import BaseChatCore

final class BaseChatSchemaTests: XCTestCase {

    func test_allModelTypes_containsExpectedTypes() {
        let typeNames = BaseChatSchema.allModelTypes.map { String(describing: $0) }

        XCTAssertTrue(typeNames.contains("ChatMessage"), "Missing ChatMessage")
        XCTAssertTrue(typeNames.contains("ChatSession"), "Missing ChatSession")
        XCTAssertTrue(typeNames.contains("SamplerPreset"), "Missing SamplerPreset")
        XCTAssertTrue(typeNames.contains("APIEndpoint"), "Missing APIEndpoint")
        XCTAssertEqual(BaseChatSchema.allModelTypes.count, 4,
                       "Expected exactly 4 model types")
    }

    func test_modelContainer_canBeCreatedInMemory() throws {
        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)

        let container = try ModelContainer(for: schema, configurations: config)
        XCTAssertNotNil(container, "Should create an in-memory container without throwing")
    }
}

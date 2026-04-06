import XCTest
import SwiftData
@testable import BaseChatCore

@available(*, deprecated)
final class BaseChatSchemaTests: XCTestCase {

    func test_allModelTypes_containsExpectedTypes() {
        let ids = BaseChatSchema.allModelTypes.map(ObjectIdentifier.init)

        // ChatMessage typealias now points to V2
        XCTAssertTrue(ids.contains(ObjectIdentifier(BaseChatSchemaV2.ChatMessage.self)), "Missing ChatMessage")
        XCTAssertTrue(ids.contains(ObjectIdentifier(BaseChatSchemaV1.ChatSession.self)), "Missing ChatSession")
        XCTAssertTrue(ids.contains(ObjectIdentifier(BaseChatSchemaV1.SamplerPreset.self)), "Missing SamplerPreset")
        XCTAssertTrue(ids.contains(ObjectIdentifier(BaseChatSchemaV1.APIEndpoint.self)), "Missing APIEndpoint")
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

import XCTest
@testable import BaseChatCore

final class ChatSessionTests: XCTestCase {

    func test_init_setsDefaults() {
        let session = ChatSession()

        XCTAssertEqual(session.title, "New Chat")
        XCTAssertEqual(session.systemPrompt, "")
        XCTAssertNotNil(session.id)
        XCTAssertNotNil(session.createdAt)
        XCTAssertNotNil(session.updatedAt)
    }

    func test_init_customTitle() {
        let session = ChatSession(title: "My Chat")
        XCTAssertEqual(session.title, "My Chat")
    }

    func test_optionalOverrides_nilByDefault() {
        let session = ChatSession()

        XCTAssertNil(session.temperature)
        XCTAssertNil(session.topP)
        XCTAssertNil(session.repeatPenalty)
        XCTAssertNil(session.promptTemplateRawValue)
        XCTAssertNil(session.contextSizeOverride)
        XCTAssertNil(session.selectedModelID)
        XCTAssertNil(session.selectedEndpointID)
    }

    func test_promptTemplate_roundTrip() {
        let session = ChatSession()

        session.promptTemplate = .llama3
        XCTAssertEqual(session.promptTemplate, .llama3)
        XCTAssertEqual(session.promptTemplateRawValue, "Llama 3")

        session.promptTemplate = nil
        XCTAssertNil(session.promptTemplate)
        XCTAssertNil(session.promptTemplateRawValue)
    }

    func test_promptTemplate_allCases() {
        let session = ChatSession()

        for template in PromptTemplate.allCases {
            session.promptTemplate = template
            XCTAssertEqual(session.promptTemplate, template,
                          "Round-trip failed for \(template.rawValue)")
        }
    }

    func test_generationOverrides_setAndRead() {
        let session = ChatSession()

        session.temperature = 1.5
        session.topP = 0.8
        session.repeatPenalty = 1.3

        XCTAssertEqual(session.temperature, 1.5)
        XCTAssertEqual(session.topP, 0.8)
        XCTAssertEqual(session.repeatPenalty, 1.3)
    }
}

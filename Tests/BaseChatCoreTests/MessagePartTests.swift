import XCTest
import SwiftData
@testable import BaseChatCore
import BaseChatTestSupport

final class MessagePartTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func test_textPart_codableRoundTrip() throws {
        let part = MessagePart.text("Hello, world!")
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_imagePart_codableRoundTrip() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let part = MessagePart.image(data: imageData, mimeType: "image/jpeg")
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_toolCallPart_codableRoundTrip() throws {
        let part = MessagePart.toolCall(id: "call_123", name: "get_weather", arguments: "{\"city\":\"London\"}")
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_toolResultPart_codableRoundTrip() throws {
        let part = MessagePart.toolResult(id: "call_123", content: "Sunny, 22C")
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_mixedParts_codableRoundTrip() throws {
        let parts: [MessagePart] = [
            .text("Here is the weather:"),
            .toolCall(id: "tc1", name: "get_weather", arguments: "{}"),
            .toolResult(id: "tc1", content: "Rainy"),
            .text("It's rainy today."),
        ]
        let data = try JSONEncoder().encode(parts)
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, parts)
    }

    // MARK: - textContent

    func test_textContent_returnsTextForTextPart() {
        let part = MessagePart.text("hello")
        XCTAssertEqual(part.textContent, "hello")
    }

    func test_textContent_returnsNilForImagePart() {
        let part = MessagePart.image(data: Data(), mimeType: "image/png")
        XCTAssertNil(part.textContent)
    }

    func test_textContent_returnsNilForToolCallPart() {
        let part = MessagePart.toolCall(id: "1", name: "fn", arguments: "{}")
        XCTAssertNil(part.textContent)
    }

    func test_textContent_returnsNilForToolResultPart() {
        let part = MessagePart.toolResult(id: "1", content: "result")
        XCTAssertNil(part.textContent)
    }

    // MARK: - ChatMessageRecord backward compatibility

    func test_chatMessageRecord_contentStringInit_createsTextPart() {
        let record = ChatMessageRecord(role: .user, content: "Hello", sessionID: UUID())
        XCTAssertEqual(record.contentParts, [.text("Hello")])
        XCTAssertEqual(record.content, "Hello")
    }

    func test_chatMessageRecord_contentParts_concatenatesTextParts() {
        let record = ChatMessageRecord(
            role: .assistant,
            contentParts: [.text("Part 1"), .toolCall(id: "t", name: "fn", arguments: "{}"), .text("Part 2")],
            sessionID: UUID()
        )
        XCTAssertEqual(record.content, "Part 1Part 2")
    }

    func test_chatMessageRecord_settingContent_replacesAllParts() {
        var record = ChatMessageRecord(
            role: .user,
            contentParts: [.text("old"), .image(data: Data(), mimeType: "image/png")],
            sessionID: UUID()
        )
        record.content = "new text only"
        XCTAssertEqual(record.contentParts, [.text("new text only")])
    }

    // MARK: - ChatMessage JSON edge cases

    func test_chatMessage_decode_malformedJSON_fallsBackToTextPart() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(role: .user, content: "original", sessionID: sessionID)
        context.insert(message)
        try context.save()

        // Corrupt the JSON directly
        message.contentPartsJSON = "not valid json"
        let parts = message.contentParts
        // Should fall back to treating the raw string as a text part
        XCTAssertEqual(parts, [.text("not valid json")])
    }

    func test_chatMessage_decode_emptyString_returnsEmptyArray() {
        let parts = BaseChatSchemaV2.ChatMessage.decode("")
        XCTAssertEqual(parts, [])
    }

    func test_chatMessage_contentParts_syncContentString() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(
            role: .assistant,
            contentParts: [.text("hello "), .toolCall(id: "t1", name: "fn", arguments: "{}"), .text("world")],
            sessionID: sessionID
        )
        context.insert(message)
        try context.save()

        // The stored content column should be the concatenation of text parts
        XCTAssertEqual(message.content, "hello world")
    }

    // MARK: - V1 -> V2 migration safety

    func test_chatMessage_v2Model_preservesContentColumn() throws {
        // Simulates the migration path: a V2 message created with the string init
        // must have both `content` (stored) and `contentPartsJSON` populated.
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(role: .user, content: "migrated text", sessionID: sessionID)
        context.insert(message)
        try context.save()

        // Both paths should return the same data
        XCTAssertEqual(message.content, "migrated text")
        XCTAssertEqual(message.contentParts, [.text("migrated text")])
        XCTAssertFalse(message.contentPartsJSON.isEmpty)
    }
}

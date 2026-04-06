import XCTest
@testable import BaseChatCore

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
}

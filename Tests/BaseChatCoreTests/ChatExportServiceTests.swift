import XCTest
@testable import BaseChatCore

final class ChatExportServiceTests: XCTestCase {

    private let sessionID = UUID()

    private func makeMessage(role: MessageRole, content: String) -> ChatMessage {
        ChatMessage(role: role, content: content, sessionID: sessionID)
    }

    // MARK: - Plain Text

    func test_exportPlainText_formatsCorrectly() {
        let messages = [
            makeMessage(role: .user, content: "Hello"),
            makeMessage(role: .assistant, content: "Hi there!")
        ]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Test Chat",
            format: .plainText
        )

        XCTAssertTrue(result.contains("User: Hello"))
        XCTAssertTrue(result.contains("Assistant: Hi there!"))
    }

    func test_exportPlainText_includesSessionTitle() {
        let result = ChatExportService.export(
            messages: [],
            sessionTitle: "My Session",
            format: .plainText
        )

        XCTAssertTrue(result.contains("Chat: My Session"))
    }

    func test_exportPlainText_handlesEmptyMessages() {
        let result = ChatExportService.export(
            messages: [],
            sessionTitle: "Empty",
            format: .plainText
        )

        XCTAssertTrue(result.contains("Chat: Empty"))
        XCTAssertFalse(result.contains("User:"))
        XCTAssertFalse(result.contains("Assistant:"))
    }

    func test_exportPlainText_skipsSystemMessages() {
        let messages = [
            makeMessage(role: .system, content: "You are a bot"),
            makeMessage(role: .user, content: "Hello"),
            makeMessage(role: .assistant, content: "Hi!")
        ]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Test",
            format: .plainText
        )

        XCTAssertFalse(result.contains("You are a bot"),
                       "System messages should not appear in plain text export")
        XCTAssertTrue(result.contains("User: Hello"))
    }

    // MARK: - Markdown

    func test_exportMarkdown_formatsWithHeaders() {
        let messages = [
            makeMessage(role: .user, content: "Tell me a story"),
            makeMessage(role: .assistant, content: "Once upon a time...")
        ]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Story",
            format: .markdown
        )

        XCTAssertTrue(result.contains("**User:**"))
        XCTAssertTrue(result.contains("**Assistant:**"))
        XCTAssertTrue(result.contains("Tell me a story"))
        XCTAssertTrue(result.contains("Once upon a time..."))
    }

    func test_exportMarkdown_includesTitleAsH1() {
        let result = ChatExportService.export(
            messages: [],
            sessionTitle: "My Story",
            format: .markdown
        )

        XCTAssertTrue(result.contains("# My Story"))
    }

    func test_exportMarkdown_skipsSystemMessages() {
        let messages = [
            makeMessage(role: .system, content: "System prompt"),
            makeMessage(role: .user, content: "Hello")
        ]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Test",
            format: .markdown
        )

        XCTAssertFalse(result.contains("System prompt"))
        XCTAssertTrue(result.contains("**User:**"))
    }

    // MARK: - Export Format

    func test_exportFormat_fileExtensions() {
        XCTAssertEqual(ExportFormat.plainText.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
    }
}

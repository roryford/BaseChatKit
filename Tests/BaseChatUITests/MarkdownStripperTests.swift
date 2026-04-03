import XCTest
@testable import BaseChatUI

final class MarkdownStripperTests: XCTestCase {

    // MARK: - Headers

    func test_strip_removesHeaders() {
        XCTAssertEqual(MarkdownStripper.strip("# Title"), "Title")
        XCTAssertEqual(MarkdownStripper.strip("## Subtitle"), "Subtitle")
        XCTAssertEqual(MarkdownStripper.strip("### Section"), "Section")
        XCTAssertEqual(MarkdownStripper.strip("###### Deep"), "Deep")
    }

    func test_strip_removesHeadersInMultilineText() {
        let input = """
        # Title
        Some text.
        ## Section
        More text.
        """
        let result = MarkdownStripper.strip(input)
        XCTAssertTrue(result.contains("Title"))
        XCTAssertTrue(result.contains("Some text."))
        XCTAssertFalse(result.contains("#"))
    }

    // MARK: - Emphasis

    func test_strip_removesBold() {
        XCTAssertEqual(MarkdownStripper.strip("**bold text**"), "bold text")
        XCTAssertEqual(MarkdownStripper.strip("__bold text__"), "bold text")
    }

    func test_strip_removesItalic() {
        XCTAssertEqual(MarkdownStripper.strip("*italic text*"), "italic text")
        XCTAssertEqual(MarkdownStripper.strip("_italic text_"), "italic text")
    }

    func test_strip_removesBoldItalic() {
        XCTAssertEqual(MarkdownStripper.strip("***bold italic***"), "bold italic")
        XCTAssertEqual(MarkdownStripper.strip("___bold italic___"), "bold italic")
    }

    func test_strip_removesStrikethrough() {
        XCTAssertEqual(MarkdownStripper.strip("~~deleted~~"), "deleted")
    }

    // MARK: - Code

    func test_strip_removesInlineCode() {
        XCTAssertEqual(MarkdownStripper.strip("Use `print()` here"), "Use print() here")
    }

    func test_strip_removesFencedCodeBlocks() {
        let input = """
        Before code.
        ```swift
        let x = 42
        ```
        After code.
        """
        let result = MarkdownStripper.strip(input)
        XCTAssertTrue(result.contains("Before code."))
        XCTAssertTrue(result.contains("After code."))
        XCTAssertFalse(result.contains("let x = 42"))
        XCTAssertFalse(result.contains("```"))
    }

    // MARK: - Links and Images

    func test_strip_extractsLinkText() {
        XCTAssertEqual(MarkdownStripper.strip("[click here](https://example.com)"), "click here")
    }

    func test_strip_extractsImageAlt() {
        XCTAssertEqual(MarkdownStripper.strip("![a photo](image.png)"), "a photo")
    }

    func test_strip_handlesImageWithEmptyAlt() {
        XCTAssertEqual(MarkdownStripper.strip("![](image.png)"), "")
    }

    // MARK: - Blockquotes

    func test_strip_removesBlockquotes() {
        XCTAssertEqual(MarkdownStripper.strip("> Quoted text"), "Quoted text")
    }

    func test_strip_removesNestedBlockquotes() {
        let input = "> Line one\n> Line two"
        let result = MarkdownStripper.strip(input)
        XCTAssertTrue(result.contains("Line one"))
        XCTAssertTrue(result.contains("Line two"))
        XCTAssertFalse(result.contains(">"))
    }

    // MARK: - Lists

    func test_strip_removesUnorderedListMarkers() {
        let input = "- Item one\n- Item two\n- Item three"
        let result = MarkdownStripper.strip(input)
        XCTAssertTrue(result.contains("Item one"))
        XCTAssertFalse(result.hasPrefix("-"))
    }

    func test_strip_removesOrderedListMarkers() {
        let input = "1. First\n2. Second\n3. Third"
        let result = MarkdownStripper.strip(input)
        XCTAssertTrue(result.contains("First"))
        XCTAssertFalse(result.contains("1."))
    }

    // MARK: - Horizontal Rules

    func test_strip_removesHorizontalRules() {
        let input = "Above\n---\nBelow"
        let result = MarkdownStripper.strip(input)
        XCTAssertTrue(result.contains("Above"))
        XCTAssertTrue(result.contains("Below"))
        XCTAssertFalse(result.contains("---"))
    }

    // MARK: - Edge Cases

    func test_strip_plainTextPassesThrough() {
        let input = "Just regular text with no formatting."
        XCTAssertEqual(MarkdownStripper.strip(input), input)
    }

    func test_strip_emptyString() {
        XCTAssertEqual(MarkdownStripper.strip(""), "")
    }

    func test_strip_collapsesMultipleBlankLines() {
        let input = "Line one\n\n\n\n\nLine two"
        let result = MarkdownStripper.strip(input)
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    func test_strip_mixedFormatting() {
        let input = "# Title\n\n**Bold** and *italic* with `code` and [a link](url)."
        let result = MarkdownStripper.strip(input)
        XCTAssertEqual(result, "Title\n\nBold and italic with code and a link.")
    }

    func test_strip_preservesMidWordUnderscores() {
        let input = "Use snake_case_names in Python."
        XCTAssertEqual(MarkdownStripper.strip(input), "Use snake_case_names in Python.")
    }

    func test_strip_removesUnderscoreEmphasisAtWordBoundaries() {
        XCTAssertEqual(MarkdownStripper.strip("_italic text_"), "italic text")
        XCTAssertEqual(MarkdownStripper.strip("__bold text__"), "bold text")
        XCTAssertEqual(MarkdownStripper.strip("___bold italic___"), "bold italic")
    }
}

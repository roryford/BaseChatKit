import XCTest
@testable import BaseChatUI
import BaseChatCore

@MainActor
final class AssistantMarkdownRenderingTests: XCTestCase {

    func test_parseBlocks_mixedMarkdownAndFencedCode_splitsIntoOrderedBlocks() {
        let input = """
        Intro **bold**

        ```swift
        let x = 1
        print(x)
        ```

        - Item 1
        [Link](https://example.com)
        """

        let blocks = AssistantMarkdownParser.parseBlocks(from: input)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .markdown)
        XCTAssertEqual(blocks[1].kind, .code(language: "swift"))
        XCTAssertEqual(blocks[2].kind, .markdown)
        XCTAssertTrue(blocks[0].text.contains("**bold**"))
        XCTAssertTrue(blocks[2].text.contains("- Item 1"))
        XCTAssertTrue(blocks[2].text.contains("[Link](https://example.com)"))
    }

    func test_parseBlocks_unclosedFenceTreatsAsMarkdownForStreaming() {
        let input = """
        Partial response
        ```swift
        let inFlight = true
        """

        let blocks = AssistantMarkdownParser.parseBlocks(from: input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .markdown)
        XCTAssertEqual(blocks[0].text, input)
    }

    func test_parseBlocks_codeOnly_parsesSingleCodeBlock() {
        let input = """
        ```python
        print("hi")
        ```
        """

        let blocks = AssistantMarkdownParser.parseBlocks(from: input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code(language: "python"))
        XCTAssertEqual(blocks[0].text, #"print("hi")"#)
    }

    func test_parseBlocks_nestedFenceInsideCodeBlock_keepsSingleOuterBlock() {
        let input = """
        Here's how:
        ```markdown
        Use fenced blocks:
        ```swift
        print("hi")
        ```
        Done
        ```
        End.
        """

        let blocks = AssistantMarkdownParser.parseBlocks(from: input)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .markdown)
        XCTAssertEqual(blocks[1].kind, .code(language: "markdown"))
        XCTAssertEqual(blocks[2].kind, .markdown)

        XCTAssertTrue(blocks[1].text.contains("```swift"))
        XCTAssertTrue(blocks[1].text.contains(#"print("hi")"#))
        XCTAssertTrue(blocks[1].text.contains("Done"))
    }

    func test_attributedString_inlineFormattingIncludesIntents() {
        let rendered = AssistantMarkdownParser.attributedString(from: "**bold** *italic* `code`")
        let rawValues = rendered.runs.compactMap(\.inlinePresentationIntent?.rawValue)
        XCTAssertTrue(rawValues.contains(InlinePresentationIntent.emphasized.rawValue))
        XCTAssertTrue(rawValues.contains(InlinePresentationIntent.stronglyEmphasized.rawValue))
        XCTAssertTrue(rawValues.contains(InlinePresentationIntent.code.rawValue))
    }

    func test_attributedString_headersListsAndLinksIncludePresentationAndLink() {
        let rendered = AssistantMarkdownParser.attributedString(from: "# Header\n- Item\n[Docs](https://example.com)")
        let hasHeader = rendered.runs.contains { run in
            run.presentationIntent?.components.contains(where: {
                if case .header(level: 1) = $0.kind { return true }
                return false
            }) == true
        }
        let hasListItem = rendered.runs.contains { run in
            run.presentationIntent?.components.contains(where: {
                if case .listItem = $0.kind { return true }
                return false
            }) == true
        }
        let hasLink = rendered.runs.contains { $0.link == URL(string: "https://example.com") }

        XCTAssertTrue(hasHeader)
        XCTAssertTrue(hasListItem)
        XCTAssertTrue(hasLink)
    }
}

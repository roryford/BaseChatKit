import XCTest
@testable import BaseChatInference

final class ThinkingBlockFilterTests: XCTestCase {

    // MARK: - Helpers

    /// Feeds each chunk through a fresh-ish filter instance and accumulates output.
    private func collect(_ chunks: [String], filter: inout ThinkingBlockFilter) -> String {
        chunks.reduce("") { $0 + filter.process($1) }
    }

    // MARK: - Tests

    /// Plain text with no think tags should pass through unchanged.
    func test_noThinkTags_passThrough() {
        var filter = ThinkingBlockFilter()
        let result = collect(["Hello, ", "world!"], filter: &filter)
        XCTAssertEqual(result, "Hello, world!")
    }

    /// A complete `<think>...</think>` block delivered in one chunk should be suppressed.
    func test_singleCompleteBlock_suppressed() {
        var filter = ThinkingBlockFilter()
        let result = filter.process("<think>hidden reasoning</think>visible answer")
        XCTAssertEqual(result, "visible answer")
    }

    /// Tags split across chunk boundaries must still be correctly filtered.
    func test_splitTags_filteredCorrectly() {
        var filter = ThinkingBlockFilter()
        let chunks = ["<thi", "nk>", "hidden", "</th", "ink>", "visible"]
        let result = collect(chunks, filter: &filter)
        XCTAssertEqual(result, "visible")
    }

    /// Nested `<think>` tags require depth tracking — only the outermost close ends suppression.
    func test_nestedTags_depthTracked() {
        var filter = ThinkingBlockFilter()
        let result = filter.process("<think>a<think>b</think>c</think>d")
        XCTAssertEqual(result, "d")
    }

    /// A think block at the very start of a response is suppressed; text after is visible.
    func test_thinkBlockAtStart_visibleAfter() {
        var filter = ThinkingBlockFilter()
        let result = filter.process("<think>reasoning</think>answer")
        XCTAssertEqual(result, "answer")
    }

    /// Multiple think blocks interleaved with visible text — only visible text is emitted.
    func test_multipleThinkBlocks_onlyVisibleEmitted() {
        var filter = ThinkingBlockFilter()
        let result = filter.process("<think>r1</think>text1<think>r2</think>text2")
        XCTAssertEqual(result, "text1text2")
    }

    /// A non-think `<` in visible text (e.g., HTML entity or comparison) passes through.
    func test_nonThinkAngleBracket_passThrough() {
        var filter = ThinkingBlockFilter()
        let result = filter.process("Hello <world>")
        XCTAssertEqual(result, "Hello <world>")
    }

    /// A partial tag at end of stream stays buffered and is not emitted as visible text.
    /// This is the safe behaviour — better to suppress than to leak tag fragments.
    func test_partialTagAtStreamEnd_notEmitted() {
        var filter = ThinkingBlockFilter()
        let result = filter.process("<thi")
        // The partial prefix is held in the buffer — nothing visible yet.
        XCTAssertEqual(result, "")
    }

    /// Visible text before a partial tag is emitted, while the partial tag is held.
    func test_visibleTextBeforePartialTag_emitted() {
        var filter = ThinkingBlockFilter()
        let result = filter.process("hello <thi")
        XCTAssertEqual(result, "hello ")
    }

    /// Multi-chunk scenario: visible text, then a think block split across many tokens.
    func test_multiChunk_mixedContent() {
        var filter = ThinkingBlockFilter()
        let chunks = ["Sure! ", "<think>", "internal reasoning", "</think>", " Here is your answer."]
        let result = collect(chunks, filter: &filter)
        XCTAssertEqual(result, "Sure!  Here is your answer.")
    }
}

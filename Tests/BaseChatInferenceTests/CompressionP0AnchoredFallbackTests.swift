import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

final class CompressionP0AnchoredFallbackTests: XCTestCase {
    private let tokenizer = CharTokenizer()

    func test_emptyOrWhitespaceSummary_fallsBackToExtractive() async {
        let compressor = AnchoredCompressor()
        compressor.generateFn = { _ in " \n\t  " }

        let messages = makeMessages(count: 10, contentLength: 80)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.stats.strategy, "anchored-fallback",
                       "Empty summary should fall back to extractive rather than injecting a placeholder.")
        XCTAssertEqual(result.messages.first?.role, "user",
                       "Extractive fallback does not inject a system summary message.")

        let budget = compressor.historyBudget(contextSize: 700, systemPrompt: nil, tokenizer: tokenizer)
        XCTAssertLessThanOrEqual(totalTokens(in: result.messages), budget,
                                 "Fallback output must respect the history budget.")
    }

    func test_customFieldNames_parsedCorrectly() async {
        let compressor = AnchoredCompressor()
        // Return summary with underscored and spaced field names (alternate style)
        compressor.generateFn = { _ in """
            CHARACTERS: Alice, Bob
            LOCATION: Forest clearing
            PLOT_THREADS: escape plan; hidden treasure
            LAST_EVENT: Alice found the map
            TONE: tense
            """
        }

        // 10 messages * 80 chars = 800 total. contextSize=1000, budget=488.
        // Compression triggers (800 > 488). Summary (~100 chars) + tail (~244 chars) fits in budget.
        let messages = makeMessages(count: 10, contentLength: 80)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 1000,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.stats.strategy, "anchored")
        guard let summary = result.messages.first, summary.role == "system" else {
            XCTFail("Expected system summary as first message")
            return
        }
        // All 5 fields should be parsed, including underscored variants
        XCTAssertTrue(summary.content.contains("PLOT_THREADS"), "Underscored field PLOT_THREADS should be preserved")
        XCTAssertTrue(summary.content.contains("LAST_EVENT"), "Underscored field LAST_EVENT should be preserved")
        XCTAssertTrue(summary.content.contains("CHARACTERS"), "Standard field should be preserved")
    }

    func test_extremelyLongSummary_truncatesThenFallsBackIfNeeded() async {
        let compressor = AnchoredCompressor()
        // Multi-word oversized summary so truncation can partially salvage it.
        compressor.generateFn = { _ in
            (0..<500).map { "word\($0)" }.joined(separator: " ")
        }

        let messages = makeMessages(count: 10, contentLength: 100)
        let contextSize = 800
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: contextSize,
            tokenizer: tokenizer
        )

        // Truncation should salvage the summary by trimming words to fit budget.
        XCTAssertEqual(result.stats.strategy, "anchored",
                       "Oversized summary should be truncated to fit, not immediately fall back.")

        let budget = compressor.historyBudget(contextSize: contextSize, systemPrompt: nil, tokenizer: tokenizer)
        XCTAssertLessThanOrEqual(totalTokens(in: result.messages), budget,
                                 "Truncated output must remain within history budget.")
    }

    func test_extremelyLongSummary_tailAloneExceedsBudget_fallsBack() async {
        let compressor = AnchoredCompressor()
        compressor.generateFn = { _ in String(repeating: "L", count: 5_000) }

        // Tail alone exceeds budget: newest message is 400 chars, budget = 800-512 = 288.
        // tailTokens (400) > budget (288), so summaryBudget <= 0 and truncation can't help.
        let messages = makeMessages(count: 10, contentLength: 400)
        let contextSize = 800
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: contextSize,
            tokenizer: tokenizer
        )

        // With no room for summary, falls back to extractive.
        XCTAssertEqual(result.stats.strategy, "anchored-fallback",
                       "When tail alone leaves no summary budget, should fall back to extractive.")

        // Note: when even the newest message exceeds the history budget, the compressor
        // still preserves it (never evicts the entire conversation). The budget is a target,
        // not a hard cap — the newest message invariant takes priority.
        XCTAssertEqual(result.stats.outputMessageCount, 1,
                       "Fallback should preserve at minimum the newest message.")
    }
}

private func makeMessages(count: Int, contentLength: Int) -> [CompressibleMessage] {
    (0..<count).map { i in
        CompressibleMessage(
            id: UUID(),
            role: i.isMultiple(of: 2) ? "user" : "assistant",
            content: String(repeating: "a", count: contentLength)
        )
    }
}

private func totalTokens(in messages: [(role: String, content: String)]) -> Int {
    messages.reduce(0) { partial, message in
        partial + message.content.count
    }
}

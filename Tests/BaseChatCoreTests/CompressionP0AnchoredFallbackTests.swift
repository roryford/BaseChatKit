import XCTest
@testable import BaseChatCore
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
        // Return summary with underscored and spaced field names (Fireside-style)
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

    func test_extremelyLongSummary_fallsBackAndRespectsBudget() async {
        let compressor = AnchoredCompressor()
        compressor.generateFn = { _ in String(repeating: "L", count: 5_000) }

        let messages = makeMessages(count: 10, contentLength: 100)
        let contextSize = 800
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: contextSize,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.stats.strategy, "anchored-fallback",
                       "Oversized summary + tail should trigger anchored fallback.")

        let budget = compressor.historyBudget(contextSize: contextSize, systemPrompt: nil, tokenizer: tokenizer)
        XCTAssertLessThanOrEqual(totalTokens(in: result.messages), budget,
                                 "Fallback output must remain within history budget.")
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

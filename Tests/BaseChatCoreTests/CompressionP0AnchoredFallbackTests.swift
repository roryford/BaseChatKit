import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

final class CompressionP0AnchoredFallbackTests: XCTestCase {
    private let tokenizer = CharTokenizer()

    func test_emptyOrWhitespaceSummary_usesStableSummaryUnavailableBehavior() async {
        let compressor = AnchoredCompressor()
        compressor.generateFn = { _ in " \n\t  " }

        let messages = makeMessages(count: 10, contentLength: 80)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.stats.strategy, "anchored",
                       "Current behavior for empty summary text is anchored with a placeholder summary.")
        XCTAssertEqual(result.messages.first?.role, "system")
        XCTAssertEqual(result.messages.first?.content, "[Summary unavailable]")

        let budget = compressor.historyBudget(contextSize: 700, systemPrompt: nil, tokenizer: tokenizer)
        XCTAssertLessThanOrEqual(totalTokens(in: result.messages), budget,
                                 "Anchored output must respect the history budget.")
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

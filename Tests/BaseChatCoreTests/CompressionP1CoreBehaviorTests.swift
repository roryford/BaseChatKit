import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

final class CompressionP1CoreBehaviorTests: XCTestCase {
    private let tokenizer = CharTokenizer()

    func test_extractiveCompressor_sameInput_producesSameOutput() async {
        let compressor = ExtractiveCompressor()
        let messages = makeAlternatingMessages(count: 16, contentLength: 120)

        let first = await compressor.compress(messages: messages, systemPrompt: nil, contextSize: 900, tokenizer: tokenizer)
        let second = await compressor.compress(messages: messages, systemPrompt: nil, contextSize: 900, tokenizer: tokenizer)

        XCTAssertEqual(first.messages.map(\.content), second.messages.map(\.content))
        XCTAssertEqual(first.messages.map(\.role), second.messages.map(\.role))
        XCTAssertEqual(first.stats.outputMessageCount, second.stats.outputMessageCount)
        XCTAssertEqual(first.stats.estimatedTokens, second.stats.estimatedTokens)
    }

    func test_extractiveCompressor_tailBudgetFractionZero_stillKeepsNewestMessage() async {
        let compressor = ExtractiveCompressor()
        compressor.tailBudgetFraction = 0.0

        let messages = makeAlternatingMessages(count: 12, contentLength: 90)
        let result = await compressor.compress(messages: messages, systemPrompt: nil, contextSize: 700, tokenizer: tokenizer)

        XCTAssertTrue(result.messages.contains(where: { $0.content == messages.last?.content }))
        XCTAssertLessThan(result.messages.count, messages.count)
    }

    func test_extractiveCompressor_tailBudgetFractionOne_prefersRecentTail() async {
        let compressor = ExtractiveCompressor()
        compressor.tailBudgetFraction = 1.0

        let messages = makeAlternatingMessages(count: 20, contentLength: 80)
        let result = await compressor.compress(messages: messages, systemPrompt: nil, contextSize: 900, tokenizer: tokenizer)

        XCTAssertFalse(result.messages.isEmpty)
        XCTAssertTrue(result.messages.contains(where: { $0.content == messages.last?.content }))
        XCTAssertLessThan(result.messages.count, messages.count)

        let firstKeptOriginalIndex = messages.firstIndex(where: { $0.content == result.messages.first?.content })
        XCTAssertNotNil(firstKeptOriginalIndex)
        XCTAssertGreaterThanOrEqual(firstKeptOriginalIndex ?? 0, messages.count / 2)
    }

    func test_extractiveCompressor_handlesCJKAndAllCapsContentSafely() async {
        let compressor = ExtractiveCompressor()
        let messages: [CompressibleMessage] = [
            .init(id: UUID(), role: "user", content: "東京で明日会いましょう。"),
            .init(id: UUID(), role: "assistant", content: "NASA ALERT MISSION STATUS GREEN"),
            .init(id: UUID(), role: "user", content: "北京 上海 深圳 广州"),
            .init(id: UUID(), role: "assistant", content: "CPU GPU RAM SSD IO"),
            .init(id: UUID(), role: "user", content: String(repeating: "z", count: 160))
        ]

        let result = await compressor.compress(messages: messages, systemPrompt: nil, contextSize: 640, tokenizer: tokenizer)

        XCTAssertFalse(result.messages.isEmpty)
        XCTAssertTrue(result.messages.contains(where: { $0.content == messages.last?.content }))
        XCTAssertLessThanOrEqual(result.messages.count, messages.count)
    }

    func test_extractiveCompressor_largeHistoryScale_overThousandMessages() async {
        let compressor = ExtractiveCompressor()
        let messages = makeAlternatingMessages(count: 1200, contentLength: 40)

        let result = await compressor.compress(messages: messages, systemPrompt: nil, contextSize: 4096, tokenizer: tokenizer)
        let budget = compressor.historyBudget(contextSize: 4096, systemPrompt: nil, tokenizer: tokenizer)

        XCTAssertFalse(result.messages.isEmpty)
        XCTAssertLessThan(result.messages.count, messages.count)
        XCTAssertLessThanOrEqual(result.stats.estimatedTokens, budget)
        XCTAssertTrue(result.messages.contains(where: { $0.content == messages.last?.content }))
    }

    func test_anchoredCompressor_slowGenerateFunction_completesAnchoredPath() async {
        let compressor = AnchoredCompressor()
        compressor.generateFn = { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return "CHARACTERS: A\nLOCATION: B\nLAST EVENT: C"
        }

        let messages = makeAlternatingMessages(count: 40, contentLength: 100)
        let result = await compressor.compress(messages: messages, systemPrompt: nil, contextSize: 900, tokenizer: tokenizer)

        XCTAssertEqual(result.stats.strategy, "anchored")
        XCTAssertEqual(result.messages.first?.role, "system")
    }

    func test_anchoredCompressor_cancelledGenerateFunction_fallsBackDeterministically() async {
        let compressor = AnchoredCompressor()
        compressor.generateFn = { _ in
            throw CancellationError()
        }

        let messages = makeAlternatingMessages(count: 40, contentLength: 100)
        let result = await compressor.compress(messages: messages, systemPrompt: nil, contextSize: 900, tokenizer: tokenizer)

        XCTAssertEqual(result.stats.strategy, "anchored-fallback")
        XCTAssertTrue(result.messages.contains(where: { $0.content == messages.last?.content }))
    }

    func test_contextWindowManager_oversizedSystemPrompt_keepsLastUserMessage() {
        let sessionID = UUID()
        let messages = [
            ChatMessageRecord(role: .assistant, content: "assistant-first", sessionID: sessionID),
            ChatMessageRecord(role: .user, content: "last-user", sessionID: sessionID),
            ChatMessageRecord(role: .assistant, content: "assistant-last", sessionID: sessionID)
        ]

        let trimmed = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: String(repeating: "p", count: 4000),
            maxTokens: 1024,
            tokenizer: tokenizer
        )

        XCTAssertEqual(trimmed.count, 1)
        XCTAssertEqual(trimmed[0].role, .user)
        XCTAssertEqual(trimmed[0].content, "last-user")
    }

    private func makeAlternatingMessages(count: Int, contentLength: Int) -> [CompressibleMessage] {
        (0..<count).map { index in
            CompressibleMessage(
                id: UUID(),
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "\(index)-" + String(repeating: index.isMultiple(of: 3) ? "A" : "x", count: contentLength)
            )
        }
    }
}

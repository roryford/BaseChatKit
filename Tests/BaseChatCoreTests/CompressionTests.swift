import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

// MARK: - CompressibleMessage Tests

final class CompressibleMessageTests: XCTestCase {

    func test_init_setsAllFields() {
        let id = UUID()
        let msg = CompressibleMessage(id: id, role: "user", content: "hello", isPinned: true)

        XCTAssertEqual(msg.id, id)
        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.content, "hello")
        XCTAssertTrue(msg.isPinned)
    }

    func test_isPinned_defaultsFalse() {
        let msg = CompressibleMessage(id: UUID(), role: "assistant", content: "hi")
        XCTAssertFalse(msg.isPinned)
    }
}

// MARK: - CompressionMode Tests

final class CompressionModeTests: XCTestCase {

    func test_rawValue_roundtrip_automatic() {
        XCTAssertEqual(CompressionMode(rawValue: "Automatic"), .automatic)
        XCTAssertEqual(CompressionMode.automatic.rawValue, "Automatic")
    }

    func test_rawValue_roundtrip_off() {
        XCTAssertEqual(CompressionMode(rawValue: "Off"), .off)
        XCTAssertEqual(CompressionMode.off.rawValue, "Off")
    }

    func test_rawValue_roundtrip_balanced() {
        XCTAssertEqual(CompressionMode(rawValue: "Balanced"), .balanced)
        XCTAssertEqual(CompressionMode.balanced.rawValue, "Balanced")
    }

    func test_rawValue_roundtrip_quality() {
        XCTAssertEqual(CompressionMode(rawValue: "Best Quality"), .quality)
        XCTAssertEqual(CompressionMode.quality.rawValue, "Best Quality")
    }

    func test_caseIterable_coversAllExpectedCases() {
        let expected: Set<CompressionMode> = [.automatic, .off, .balanced, .quality]
        let all = Set(CompressionMode.allCases)
        XCTAssertEqual(all, expected)
    }
}

// MARK: - ExtractiveCompressor Tests

final class ExtractiveCompressorTests: XCTestCase {
    private let tokenizer = CharTokenizer()
    private let compressor = ExtractiveCompressor()

    func test_emptyMessages_returnsEmptyResult() async {
        let result = await compressor.compress(
            messages: [],
            systemPrompt: nil,
            contextSize: 1000,
            tokenizer: tokenizer
        )

        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertEqual(result.stats.originalNodeCount, 0)
        XCTAssertEqual(result.stats.outputMessageCount, 0)
        XCTAssertEqual(result.stats.estimatedTokens, 0)
    }

    func test_allMessagesFitInBudget_returnsAllUnchanged() async {
        // 3 messages × 10 chars = 30 tokens.
        // contextSize = 1000 → budget = 1000 - 512 (responseBuffer) = 488 → all fit.
        let messages = makeMessages(count: 3, contentLength: 10)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 1000,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.messages.count, messages.count,
                       "All messages should be returned when they fit in budget")
        XCTAssertEqual(result.stats.compressionRatio, 1.0)
    }

    func test_messagesExceedingBudget_keepsNewest() async {
        // 10 messages × 100 chars = 1000 tokens.
        // contextSize = 700 → budget = 700 - 512 = 188 → cannot keep all.
        let messages = makeMessages(count: 10, contentLength: 100)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertLessThan(result.messages.count, messages.count,
                          "Some messages should be dropped to fit in budget")
        // The newest message (last in array) must be in the output.
        let lastContent = messages.last!.content
        XCTAssertTrue(result.messages.contains(where: { $0.content == lastContent }),
                      "Newest message must be preserved")
    }

    func test_pinnedMessage_alwaysPreserved() async {
        // Sabotage setup: 5 messages × 100 chars = 500 tokens, contextSize = 620.
        // budget = 620 - 512 = 108 tokens. Without pinning, only newest ~1 message fits.
        // Pinned message is the oldest (index 0) — verify it survives.
        var messages = makeMessages(count: 5, contentLength: 100)
        let pinnedID = UUID()
        messages[0] = CompressibleMessage(
            id: pinnedID,
            role: "user",
            content: String(repeating: "p", count: 100),
            isPinned: true
        )

        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 620,
            tokenizer: tokenizer
        )

        // Verify the budget is tight enough that the pinned message would be evicted
        // if pinning were not respected (i.e., the total unpinned tokens exceed budget).
        let totalTokens = messages.reduce(0) { $0 + $1.content.count }
        let budget = 620 - 512
        XCTAssertGreaterThan(totalTokens, budget,
                             "Precondition: messages must exceed budget to test pinning")

        XCTAssertTrue(result.messages.contains(where: { $0.content == messages[0].content }),
                      "Pinned message at index 0 must survive regardless of budget")
    }

    func test_outputTokenCount_withinBudget() async {
        // 20 messages × 50 chars = 1000 tokens.
        // contextSize = 700 → budget = 700 - 512 = 188.
        let messages = makeMessages(count: 20, contentLength: 50)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        let outputTokens = result.messages.reduce(0) { $0 + $1.content.count }
        let budget = 700 - 512
        XCTAssertLessThanOrEqual(outputTokens, budget,
                                 "Output token count must be within history budget")
    }

    func test_strategyName_isNotEmpty() {
        XCTAssertFalse(compressor.strategyName.isEmpty)
    }

    // MARK: - Protocol helper tests (via ExtractiveCompressor)

    func test_messageTuples_mapsRolesAndContentCorrectly() {
        let messages = [
            CompressibleMessage(id: UUID(), role: "user", content: "hello"),
            CompressibleMessage(id: UUID(), role: "assistant", content: "world"),
        ]
        let tuples = compressor.messageTuples(from: messages)

        XCTAssertEqual(tuples.count, 2)
        XCTAssertEqual(tuples[0].role, "user")
        XCTAssertEqual(tuples[0].content, "hello")
        XCTAssertEqual(tuples[1].role, "assistant")
        XCTAssertEqual(tuples[1].content, "world")
    }

    func test_totalTokens_sumsAcrossAllMessages() {
        // CharTokenizer: 1 token per char, min 1.
        let tuples: [(role: String, content: String)] = [
            (role: "user", content: "abcde"),      // 5 chars → 5 tokens
            (role: "assistant", content: "fghij"),  // 5 chars → 5 tokens
        ]
        let total = compressor.totalTokens(of: tuples, tokenizer: tokenizer)
        XCTAssertEqual(total, 10)
    }

    func test_historyBudget_subtractsSystemPromptAndResponseBuffer() {
        // contextSize = 1000, systemPrompt = 20 chars → 20 tokens, responseBuffer = 512.
        // budget = 1000 - 20 - 512 = 468.
        let systemPrompt = String(repeating: "s", count: 20)
        let budget = compressor.historyBudget(
            contextSize: 1000,
            systemPrompt: systemPrompt,
            responseBuffer: 512,
            tokenizer: tokenizer
        )
        XCTAssertEqual(budget, 468)
    }
}

// MARK: - AnchoredCompressor Tests

final class AnchoredCompressorTests: XCTestCase {
    private let tokenizer = CharTokenizer()

    func test_withoutGenerateFn_fallsBackToExtractiveCompressor() async {
        let compressor = AnchoredCompressor()
        // No generateFn set.

        // 10 messages × 100 chars = 1000 tokens, contextSize = 700 → needs compression.
        let messages = makeMessages(count: 10, contentLength: 100)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        // Falls back: strategy should be "anchored-fallback".
        XCTAssertEqual(result.stats.strategy, "anchored-fallback",
                       "Without generateFn, strategy should be 'anchored-fallback'")
    }

    func test_withValidGenerateFn_summaryIsPrependedToTail() async {
        let compressor = AnchoredCompressor()
        let summaryContent = "CHARACTERS: Alice\nLOCATION: Forest\nLAST EVENT: She ran away"
        compressor.generateFn = { _ in summaryContent }

        // 10 messages × 100 chars = 1000 tokens, contextSize = 700 → needs compression.
        let messages = makeMessages(count: 10, contentLength: 100)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.stats.strategy, "anchored",
                       "With valid generateFn, strategy should be 'anchored'")
        // The first output message should be a system summary.
        XCTAssertEqual(result.messages.first?.role, "system",
                       "Summary should be prepended as a system message")
        XCTAssertFalse(result.messages.first?.content.isEmpty ?? true,
                       "Summary content should not be empty")
    }

    func test_withThrowingGenerateFn_fallsBackToExtractiveCompressor() async {
        struct TestError: Error {}
        let compressor = AnchoredCompressor()
        compressor.generateFn = { _ in throw TestError() }

        let messages = makeMessages(count: 10, contentLength: 100)
        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.stats.strategy, "anchored-fallback",
                       "Throwing generateFn must fall back to 'anchored-fallback'")
    }

    func test_summaryTemplate_customValueUsedInPrompt() async {
        let compressor = AnchoredCompressor()
        let customTemplate = "Summarize this: {old_nodes_text}"
        compressor.summaryTemplate = customTemplate

        var capturedPrompt: String?
        compressor.generateFn = { prompt in
            capturedPrompt = prompt
            return "CHARACTERS: Bob\nLOCATION: City"
        }

        // Need enough messages to force old messages to be summarized.
        // 10 messages × 100 chars = 1000 tokens, contextSize = 700 → needs compression.
        let messages = makeMessages(count: 10, contentLength: 100)
        _ = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        guard let prompt = capturedPrompt else {
            XCTFail("generateFn was not called")
            return
        }
        XCTAssertTrue(prompt.hasPrefix("Summarize this: "),
                      "Custom summaryTemplate prefix should appear in the prompt")
        XCTAssertFalse(prompt.contains("{old_nodes_text}"),
                       "Placeholder should be replaced in prompt, not appear verbatim")
    }

    func test_strategyName_isNotEmpty() {
        XCTAssertFalse(AnchoredCompressor().strategyName.isEmpty)
    }
}

// MARK: - CompressionOrchestrator Tests

@MainActor
final class CompressionOrchestratorTests: XCTestCase {
    private let tokenizer = CharTokenizer()

    func test_shouldCompress_returnsFalse_whenModeIsOff() {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .off

        let messages = makeMessages(count: 100, contentLength: 100)
        let result = orchestrator.shouldCompress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 1000,
            tokenizer: tokenizer
        )

        XCTAssertFalse(result, "shouldCompress must be false when mode is .off")
    }

    func test_shouldCompress_returnsFalse_whenBelowThreshold() {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .automatic

        // 2 messages × 10 chars = 20 tokens.
        // contextSize = 1000. usableContext = 488. utilization = 20/488 ≈ 4%, well below 75%.
        let messages = makeMessages(count: 2, contentLength: 10)
        let result = orchestrator.shouldCompress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 1000,
            tokenizer: tokenizer
        )

        XCTAssertFalse(result, "shouldCompress must be false when utilization is low")
    }

    func test_shouldCompress_returnsTrue_atOrAboveThreshold() {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .automatic

        // contextSize = 700 → usableContext = 700 - 512 = 188.
        // threshold for contextSize <= 16000 = 0.75 → trigger at 188 * 0.75 = 141 tokens.
        // 2 messages × 100 chars = 200 tokens → utilization = 200/188 ≈ 106% → triggers.
        let messages = makeMessages(count: 2, contentLength: 100)
        let result = orchestrator.shouldCompress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertTrue(result, "shouldCompress must be true when utilization is at or above threshold")
    }

    func test_compress_withBalancedMode_routesToExtractiveWhenNoGenerateFn() async {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .balanced
        // .balanced routes directly to ExtractiveCompressor, not AnchoredCompressor.

        let messages = makeMessages(count: 10, contentLength: 100)
        let result = await orchestrator.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        // .balanced uses ExtractiveCompressor directly → strategy is always "extractive".
        XCTAssertEqual(result.stats.strategy, "extractive",
                       "Balanced mode routes to ExtractiveCompressor (strategy 'extractive'), not AnchoredCompressor")
    }

    func test_compress_withQualityMode_routesToAnchoredWhenGenerateFnSet() async {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .quality
        orchestrator.anchored.generateFn = { _ in "CHARACTERS: X\nLOCATION: Y" }

        let messages = makeMessages(count: 10, contentLength: 100)
        let result = await orchestrator.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.stats.strategy, "anchored",
                       "Quality mode with generateFn should route to AnchoredCompressor")
    }

    func test_compress_withAutomaticMode_smallContext_routesToExtractiveCompressor() async {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .automatic
        // contextSize < 6000 → selectStrategy picks extractive directly.
        // No generateFn needed.

        let messages = makeMessages(count: 10, contentLength: 100)
        let result = await orchestrator.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        // ExtractiveCompressor produces "extractive" strategy name.
        XCTAssertEqual(result.stats.strategy, "extractive",
                       "Automatic mode with small context should route to ExtractiveCompressor")
    }

    func test_compress_withAutomaticMode_largeContext_routesToAnchoredWhenGenerateFnSet() async {
        let orchestrator = CompressionOrchestrator()
        orchestrator.mode = .automatic
        orchestrator.anchored.generateFn = { _ in "CHARACTERS: X\nLOCATION: Y" }

        // contextSize >= 6000 and generateFn set → selectStrategy picks anchored.
        // 200 messages × 50 chars = 10000 tokens, contextSize = 10000 → compress.
        let messages = makeMessages(count: 200, contentLength: 50)
        let result = await orchestrator.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 10_000,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.stats.strategy, "anchored",
                       "Automatic mode with large context and generateFn should route to AnchoredCompressor")
    }

    func test_modeChange_affectsSubsequentShouldCompressCalls() {
        let orchestrator = CompressionOrchestrator()
        let messages = makeMessages(count: 100, contentLength: 100)

        orchestrator.mode = .automatic
        let whenAutomatic = orchestrator.shouldCompress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        orchestrator.mode = .off
        let whenOff = orchestrator.shouldCompress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 700,
            tokenizer: tokenizer
        )

        XCTAssertTrue(whenAutomatic, "Should compress when mode is automatic and utilization is high")
        XCTAssertFalse(whenOff, "Should not compress after mode is changed to .off")
    }
}

// MARK: - Test Data Helpers

private func makeMessages(count: Int, contentLength: Int = 10) -> [CompressibleMessage] {
    (0..<count).map { i in
        CompressibleMessage(
            id: UUID(),
            role: i.isMultiple(of: 2) ? "user" : "assistant",
            content: String(repeating: "a", count: contentLength)
        )
    }
}

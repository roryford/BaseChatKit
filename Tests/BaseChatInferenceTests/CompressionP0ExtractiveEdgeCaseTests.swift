import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

final class CompressionP0ExtractiveEdgeCaseTests: XCTestCase {
    private let compressor = ExtractiveCompressor()
    private let tokenizer = CharTokenizer()

    func test_singleMessage_overBudget_isStillPreservedVerbatim() async {
        let content = String(repeating: "S", count: 120)
        let message = CompressibleMessage(id: UUID(), role: "user", content: content)

        let result = await compressor.compress(
            messages: [message],
            systemPrompt: nil,
            contextSize: 520,
            tokenizer: tokenizer
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].role, "user")
        XCTAssertEqual(result.messages[0].content, content)
        XCTAssertEqual(result.stats.originalNodeCount, 1)
        XCTAssertEqual(result.stats.outputMessageCount, 1)
    }

    func test_whitespaceOnlyMessage_whenCompressed_isHandledWithoutMutation() async {
        let whitespace = " \n\t   "
        let messages = [
            CompressibleMessage(id: UUID(), role: "user", content: String(repeating: "A", count: 100)),
            CompressibleMessage(id: UUID(), role: "assistant", content: whitespace),
        ]

        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 530,
            tokenizer: tokenizer
        )

        XCTAssertFalse(result.messages.isEmpty)
        XCTAssertTrue(
            result.messages.contains(where: { $0.content == whitespace }),
            "Whitespace-only content should be preserved exactly if selected"
        )
        XCTAssertTrue(
            result.messages.allSatisfy { original in
                messages.contains(where: { $0.role == original.role && $0.content == original.content })
            },
            "Compressor should only emit original messages verbatim"
        )
    }

    func test_multiplePinnedMessages_exceedingBudget_preservesAllPinnedEvenWhenOverflowingBudget() async {
        let messages = [
            CompressibleMessage(id: UUID(), role: "user", content: String(repeating: "P", count: 80), isPinned: true),
            CompressibleMessage(id: UUID(), role: "assistant", content: String(repeating: "X", count: 90)),
            CompressibleMessage(id: UUID(), role: "user", content: String(repeating: "Q", count: 70), isPinned: true),
            CompressibleMessage(id: UUID(), role: "assistant", content: String(repeating: "N", count: 60)),
        ]

        let contextSize = 560
        let budget = compressor.historyBudget(
            contextSize: contextSize,
            systemPrompt: nil,
            tokenizer: tokenizer
        )

        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: contextSize,
            tokenizer: tokenizer
        )

        let pinnedContents = Set(messages.filter(\.isPinned).map(\.content))
        let resultContents = Set(result.messages.map(\.content))

        XCTAssertTrue(
            pinnedContents.isSubset(of: resultContents),
            "All pinned messages must survive even under severe budget pressure"
        )
        XCTAssertTrue(
            result.messages.contains(where: { $0.content == messages.last?.content }),
            "Newest message must always be preserved, even when pinned messages dominate budget"
        )

        let outputTokens = result.messages.reduce(0) { partial, message in
            partial + tokenizer.tokenCount(message.content)
        }
        XCTAssertGreaterThan(outputTokens, budget, "Pinned preservation may legally overflow budget")
    }

    func test_compressedOutput_isAlwaysChronological() async {
        let messages = [
            CompressibleMessage(id: UUID(), role: "user", content: marker(0)),
            CompressibleMessage(id: UUID(), role: "assistant", content: marker(1)),
            CompressibleMessage(id: UUID(), role: "user", content: marker(2)),
            CompressibleMessage(id: UUID(), role: "assistant", content: marker(3)),
            CompressibleMessage(id: UUID(), role: "user", content: marker(4)),
            CompressibleMessage(id: UUID(), role: "assistant", content: marker(5)),
        ]

        let result = await compressor.compress(
            messages: messages,
            systemPrompt: nil,
            contextSize: 680,
            tokenizer: tokenizer
        )

        let originalIndexByContent = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($1.content, $0) })
        let outputIndices = result.messages.compactMap { originalIndexByContent[$0.content] }

        XCTAssertEqual(outputIndices, outputIndices.sorted(), "Output must remain chronological")
        XCTAssertEqual(outputIndices, [3, 4, 5], "Expected deterministic extractive selection for this fixture")
    }

    private func marker(_ index: Int) -> String {
        "msg-\(index)-" + String(repeating: String(index), count: 40)
    }
}

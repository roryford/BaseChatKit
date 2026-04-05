import Testing
import Foundation
@testable import BaseChatCore

@Suite("PromptSlotPosition")
struct PromptSlotPositionTests {

    // MARK: - Sort ordering

    @Test func test_sortIndex_systemPreamble_isLowestAmongTopSlots() {
        let mc = 10
        #expect(
            PromptSlotPosition.systemPreamble.sortIndex(messageCount: mc) <
            PromptSlotPosition.contextSetup.sortIndex(messageCount: mc)
        )
    }

    @Test func test_sortIndex_contextSetup_comesBeforeAllHistorySlots() {
        let mc = 10
        let ctxIdx = PromptSlotPosition.contextSetup.sortIndex(messageCount: mc)
        #expect(ctxIdx < PromptSlotPosition.bottomOfHistory.sortIndex(messageCount: mc))
        #expect(ctxIdx < PromptSlotPosition.inline.sortIndex(messageCount: mc))
        #expect(ctxIdx < PromptSlotPosition.atDepth(1).sortIndex(messageCount: mc))
        #expect(ctxIdx < PromptSlotPosition.topOfHistory.sortIndex(messageCount: mc))
    }

    @Test func test_sortIndex_atDepth_orderedByN() {
        let mc = 10
        #expect(
            PromptSlotPosition.atDepth(1).sortIndex(messageCount: mc) <
            PromptSlotPosition.atDepth(5).sortIndex(messageCount: mc)
        )
    }

    @Test func test_sortIndex_topOfHistory_higherThanAtDepthMessageCountMinusOne() {
        let mc = 5
        #expect(
            PromptSlotPosition.atDepth(mc - 1).sortIndex(messageCount: mc) <
            PromptSlotPosition.topOfHistory.sortIndex(messageCount: mc)
        )
    }

    // MARK: - Insertion depth

    @Test func test_insertionDepth_atDepthZero_equalsBottomOfHistory() {
        let mc = 5
        #expect(
            PromptSlotPosition.atDepth(0).insertionDepth(messageCount: mc) ==
            PromptSlotPosition.bottomOfHistory.insertionDepth(messageCount: mc)
        )
    }

    @Test func test_insertionDepth_topOfHistory_equalsMessageCount() {
        let mc = 7
        #expect(PromptSlotPosition.topOfHistory.insertionDepth(messageCount: mc) == mc)
    }

    @Test func test_insertionDepth_inline_equalsZero() {
        #expect(PromptSlotPosition.inline.insertionDepth(messageCount: 10) == 0)
    }

    @Test func test_insertionDepth_bottomOfHistory_equalsZero() {
        #expect(PromptSlotPosition.bottomOfHistory.insertionDepth(messageCount: 10) == 0)
    }

    // MARK: - isTopSlot

    @Test func test_isTopSlot_systemPreambleAndContextSetup_areTopSlots() {
        #expect(PromptSlotPosition.systemPreamble.isTopSlot)
        #expect(PromptSlotPosition.contextSetup.isTopSlot)
    }

    @Test func test_isTopSlot_historyPositions_areNotTopSlots() {
        #expect(!PromptSlotPosition.atDepth(0).isTopSlot)
        #expect(!PromptSlotPosition.atDepth(3).isTopSlot)
        #expect(!PromptSlotPosition.topOfHistory.isTopSlot)
        #expect(!PromptSlotPosition.bottomOfHistory.isTopSlot)
        #expect(!PromptSlotPosition.inline.isTopSlot)
    }

    // MARK: - Codable round-trip

    @Test func test_codable_roundTrip_allCases() throws {
        let cases: [PromptSlotPosition] = [
            .systemPreamble, .contextSetup, .atDepth(0), .atDepth(3),
            .topOfHistory, .bottomOfHistory, .inline,
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for position in cases {
            let data = try encoder.encode(position)
            let decoded = try decoder.decode(PromptSlotPosition.self, from: data)
            #expect(decoded == position)
        }
    }

    // MARK: - Assembler placement

    private func makeMessage(role: MessageRole, content: String) -> ChatMessageRecord {
        ChatMessageRecord(role: role, content: content, sessionID: UUID())
    }

    private struct CharTokenizer: TokenizerProvider {
        func tokenCount(_ text: String) -> Int { max(1, text.count) }
    }

    @Test func test_assembler_systemPreamble_appearsBeforeContextSetup() {
        let slots = [
            PromptSlot(id: "ctx", content: "context", position: .contextSetup, label: "Ctx"),
            PromptSlot(id: "pre", content: "preamble", position: .systemPreamble, label: "Pre"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 1000, tokenizer: CharTokenizer()
        )
        #expect(result.orderedSlots[0].id == "pre")
        #expect(result.orderedSlots[1].id == "ctx")
        // Both should appear as system messages at the top
        #expect(result.messages[0].content == "preamble")
        #expect(result.messages[1].content == "context")
    }

    @Test func test_assembler_atDepth_insertedNFromBottom() {
        let messages = (0..<5).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "note", content: "note", position: .atDepth(2), label: "Note"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        let contents = result.messages.map(\.content)
        if let noteIndex = contents.firstIndex(of: "note") {
            // 2 messages after the note
            #expect(contents.count - noteIndex - 1 == 2)
        } else {
            Issue.record("note slot not found in messages")
        }
    }

    @Test func test_assembler_topOfHistory_appearsBeforeAllMessages() {
        let messages = (0..<3).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "top", content: "top note", position: .topOfHistory, label: "Top"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(result.messages.first?.content == "top note")
    }

    @Test func test_assembler_bottomOfHistory_appearsAfterAllMessages() {
        let messages = (0..<3).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "bottom", content: "bottom note", position: .bottomOfHistory, label: "Bottom"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(result.messages.last?.content == "bottom note")
    }

    @Test func test_assembler_atDepthZero_placedSameAsBottomOfHistory() {
        let messages = (0..<3).map { makeMessage(role: .user, content: "msg\($0)") }

        let r1 = PromptAssembler.assemble(
            slots: [PromptSlot(id: "a", content: "note", position: .atDepth(0), label: "A")],
            messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        let r2 = PromptAssembler.assemble(
            slots: [PromptSlot(id: "b", content: "note", position: .bottomOfHistory, label: "B")],
            messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )

        #expect(r1.messages.map(\.content) == r2.messages.map(\.content))
    }

    @Test func test_assembler_inline_placedAtEnd() {
        let messages = (0..<3).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "il", content: "inline note", position: .inline, label: "Inline"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(result.messages.last?.content == "inline note")
    }
}

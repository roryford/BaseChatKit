import Testing
import Foundation
@testable import BaseChatInference

/// Deterministic tokenizer: 1 token per character.
private struct CharTokenizer: TokenizerProvider {
    func tokenCount(_ text: String) -> Int { max(1, text.count) }
}

@Suite("PromptSlotRole + BudgetPolicy")
struct PromptSlotRoleTests {

    // MARK: - PromptSlotRole.Codable

    @Test func test_codable_roundTrip_allCases() throws {
        let cases: [PromptSlotRole] = [
            .system, .characterContext, .retrieval, .archival,
            .userInstruction, .conversationHistory, .custom("memory"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for role in cases {
            let data = try encoder.encode(role)
            let decoded = try decoder.decode(PromptSlotRole.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test func test_decode_unknownType_throws() {
        let json = #"{"type":"bogus"}"#
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PromptSlotRole.self, from: data)
        }
    }

    // MARK: - BudgetPolicy default ordering

    @Test func test_defaultPolicy_orderingMatchesIssue110() {
        let p = BudgetPolicy.default
        // Lower number = higher priority (kept first).
        #expect(p.priority(for: .system) <
                p.priority(for: .characterContext))
        #expect(p.priority(for: .characterContext) <
                p.priority(for: .retrieval))
        #expect(p.priority(for: .retrieval) <
                p.priority(for: .archival))
        #expect(p.priority(for: .archival) <
                p.priority(for: .userInstruction))
        #expect(p.priority(for: .userInstruction) <
                p.priority(for: .conversationHistory))
    }

    @Test func test_defaultPolicy_customRoleHasLowestPriority() {
        let p = BudgetPolicy.default
        #expect(p.priority(for: .custom("anything")) >
                p.priority(for: .conversationHistory))
    }

    // MARK: - PromptSlot defaults

    @Test func test_promptSlot_defaultsToUserInstruction() {
        let slot = PromptSlot(id: "x", content: "hi", label: "X")
        #expect(slot.role == .userInstruction)
    }

    @Test func test_promptSlot_acceptsExplicitRole() {
        let slot = PromptSlot(id: "char", content: "Persona", role: .characterContext, label: "Char")
        #expect(slot.role == .characterContext)
    }

    // MARK: - Per-role caps

    @Test func test_assembler_roleCap_clampsCombinedRoleTokens() {
        // Two retrieval slots totalling 30 tokens, capped at 20.
        // Cap is applied in input-array order: first slot gets up to 20,
        // remaining (10 → 0) for the second slot. Slots that drop to 0 are
        // pruned from the assembled output.
        let slots = [
            PromptSlot(id: "r1", content: "aaaaaaaaaaaaaaa", role: .retrieval, label: "R1"), // 15
            PromptSlot(id: "r2", content: "bbbbbbbbbbbbbbb", role: .retrieval, label: "R2"), // 15
        ]
        var policy = BudgetPolicy.default
        policy.caps[.retrieval] = 20
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: policy
        )
        #expect(result.budgetBreakdown["r1"] == 15)
        // Second slot's remaining cap is 5 → kept at 5 tokens.
        #expect(result.budgetBreakdown["r2"] == 5)
    }

    @Test func test_assembler_systemRole_ignoresCapAndPriorityTrim() {
        // Even if the caller sets a cap on .system, the assembler ignores it.
        // The system slot is also never trimmed when the budget overflows.
        let slots = [
            PromptSlot(id: "ret", content: String(repeating: "r", count: 100),
                       role: .retrieval, label: "Ret"),
        ]
        var policy = BudgetPolicy.default
        policy.caps[.system] = 1
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: "Be helpful",
            contextSize: 50, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: policy
        )
        // System ("Be helpful" = 10 chars/tokens) survives intact even though
        // the slotBudget is 50 and the total content is 110.
        #expect(result.budgetBreakdown["system"] == 10)
    }

    // MARK: - Priority-driven trimming

    @Test func test_assembler_priorityTrim_dropsLowestRoleFirst() {
        // slotBudget = 30. Total content = 60.
        // Default priority: characterContext (kept) > retrieval > userInstruction > custom (trimmed first).
        let slots = [
            PromptSlot(id: "char", content: String(repeating: "c", count: 20),
                       role: .characterContext, label: "Char"),
            PromptSlot(id: "ret", content: String(repeating: "r", count: 20),
                       role: .retrieval, label: "Ret"),
            PromptSlot(id: "cust", content: String(repeating: "x", count: 20),
                       role: .custom("notes"), label: "Custom"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 30, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: .default
        )
        // Custom (lowest priority) is fully removed first (-20 → 40 left).
        // Retrieval (next lowest) is trimmed to absorb the remaining 10 (40-30).
        // Character context survives untouched.
        #expect(result.budgetBreakdown["char"] == 20)
        #expect(result.budgetBreakdown["ret"] == 10)
        #expect(result.budgetBreakdown["cust"] == nil) // dropped
    }

    @Test func test_assembler_priorityTrim_systemAlwaysSurvives() {
        // Even with an impossible budget, the system slot is never trimmed.
        // Other slots are trimmed/dropped to make as much room as possible.
        let slots = [
            PromptSlot(id: "ret", content: String(repeating: "r", count: 50),
                       role: .retrieval, label: "Ret"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: String(repeating: "s", count: 40),
            contextSize: 30, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: .default
        )
        #expect(result.budgetBreakdown["system"] == 40)
        #expect(result.budgetBreakdown["ret"] == nil) // dropped to fit
    }

    @Test func test_assembler_priorityTrim_customRolePolicyOverride() {
        // Caller can promote a custom role above conversationHistory.
        var policy = BudgetPolicy.default
        let custom = PromptSlotRole.custom("memory")
        policy.priorities[custom] = 1 // higher priority than character context, etc.

        let slots = [
            // Same priority numerically (1) means input order is the tiebreaker
            // for trimming order — second one trims first.
            PromptSlot(id: "memo", content: String(repeating: "m", count: 20),
                       role: custom, label: "Memo"),
            PromptSlot(id: "char", content: String(repeating: "c", count: 20),
                       role: .characterContext, label: "Char"),
            PromptSlot(id: "ret", content: String(repeating: "r", count: 20),
                       role: .retrieval, label: "Ret"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 40, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: policy
        )
        // ret (lowest) is dropped first; we still need 0 more from the 60 → 40
        // budget cut, so memo and char survive intact.
        #expect(result.budgetBreakdown["memo"] == 20)
        #expect(result.budgetBreakdown["char"] == 20)
        #expect(result.budgetBreakdown["ret"] == nil)
    }

    // MARK: - Backwards compatibility

    @Test func test_assembler_noPolicyOverride_preservesPreRoleBehavior() {
        // Without role caps and within budget, the result is identical to the
        // pre-role behaviour — no slot is trimmed by policy.
        let slots = [
            PromptSlot(id: "a", content: "aaaa", label: "A"),
            PromptSlot(id: "b", content: "bb", label: "B"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: "sys",
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(result.budgetBreakdown["a"] == 4)
        #expect(result.budgetBreakdown["b"] == 2)
        #expect(result.budgetBreakdown["system"] == 3)
    }
}

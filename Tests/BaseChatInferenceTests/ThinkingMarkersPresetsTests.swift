import XCTest
@testable import BaseChatInference

// MARK: - Helpers

private func collectVisible(_ events: [GenerationEvent]) -> String {
    events.compactMap { if case .token(let t) = $0 { return t } else { return nil } }.joined()
}

private func collectThinking(_ events: [GenerationEvent]) -> String {
    events.compactMap { if case .thinkingToken(let t) = $0 { return t } else { return nil } }.joined()
}

private func countCompletions(_ events: [GenerationEvent]) -> Int {
    events.filter { if case .thinkingComplete = $0 { return true } else { return false } }.count
}

/// Runs a single-block reasoning payload through a `ThinkingParser` parameterized
/// by `markers` and returns the (thinking, visible, completion-count) tuple.
private func runParser(_ markers: ThinkingMarkers, open: String, close: String) -> (thinking: String, visible: String, completions: Int) {
    var parser = ThinkingParser(markers: markers)
    let input = "\(open)reason\(close)answer"
    let events = parser.process(input)
    let final = parser.finalize()
    let all = events + final
    return (collectThinking(all), collectVisible(all), countCompletions(all))
}

/// Tests for the named `ThinkingMarkers` presets and the `forModel(named:)`
/// lookup helper added in issue #603.
final class ThinkingMarkersPresetsTests: XCTestCase {

    // MARK: - Preset tag pairs

    func test_mistralReasoning_tagsAreThinkingPair() {
        XCTAssertEqual(ThinkingMarkers.mistralReasoning.open, "<thinking>")
        XCTAssertEqual(ThinkingMarkers.mistralReasoning.close, "</thinking>")
    }

    func test_phi4_tagsAreReasoningPair() {
        XCTAssertEqual(ThinkingMarkers.phi4.open, "<reasoning>")
        XCTAssertEqual(ThinkingMarkers.phi4.close, "</reasoning>")
    }

    func test_reflection_tagsAreReflectionPair() {
        XCTAssertEqual(ThinkingMarkers.reflection.open, "<reflection>")
        XCTAssertEqual(ThinkingMarkers.reflection.close, "</reflection>")
    }

    // MARK: - End-to-end ThinkingParser with each preset

    func test_mistralReasoning_parsesSingleBlock() {
        let r = runParser(.mistralReasoning, open: "<thinking>", close: "</thinking>")
        XCTAssertEqual(r.thinking, "reason",
            "Content between <thinking>…</thinking> must be emitted as .thinkingToken")
        XCTAssertEqual(r.visible, "answer",
            "Content after </thinking> must be emitted as .token")
        XCTAssertEqual(r.completions, 1,
            "Exactly one .thinkingComplete event should fire on the 1→0 depth transition")

        // Sabotage check: swapping `.mistralReasoning` for `.qwen3` makes the parser
        // search for the `<think>` / `</think>` pair. Both are substrings of the
        // `<thinking>` / `</thinking>` payload, so the parser consumes different
        // ranges and the visible text becomes "ing>answer" — the XCTAssertEqual fails.
    }

    func test_phi4_parsesSingleBlock() {
        let r = runParser(.phi4, open: "<reasoning>", close: "</reasoning>")
        XCTAssertEqual(r.thinking, "reason")
        XCTAssertEqual(r.visible, "answer")
        XCTAssertEqual(r.completions, 1)
    }

    func test_reflection_parsesSingleBlock() {
        let r = runParser(.reflection, open: "<reflection>", close: "</reflection>")
        XCTAssertEqual(r.thinking, "reason")
        XCTAssertEqual(r.visible, "answer")
        XCTAssertEqual(r.completions, 1)
    }

    // MARK: - Holdback for each preset

    func test_mistralReasoning_holdbackEquals11() {
        // max("<thinking>".count=10, "</thinking>".count=11) = 11
        XCTAssertEqual(ThinkingMarkers.mistralReasoning.holdback, 11)
    }

    func test_phi4_holdbackEquals12() {
        // max("<reasoning>".count=11, "</reasoning>".count=12) = 12
        XCTAssertEqual(ThinkingMarkers.phi4.holdback, 12)
    }

    func test_reflection_holdbackEquals13() {
        // max("<reflection>".count=12, "</reflection>".count=13) = 13
        XCTAssertEqual(ThinkingMarkers.reflection.holdback, 13)
    }

    // MARK: - Split-tag robustness for new presets

    func test_mistralReasoning_splitOpenTagAcrossChunks() {
        var parser = ThinkingParser(markers: .mistralReasoning)
        let e1 = parser.process("<thin")
        let e2 = parser.process("king>reason</thinking>answer")
        let all = e1 + e2 + parser.finalize()
        XCTAssertEqual(collectThinking(all), "reason",
            "Split <thinking> open tag must reassemble across chunk boundary")
        XCTAssertEqual(collectVisible(all), "answer")
    }

    // MARK: - forModel(named:) — family matches

    func test_forModel_qwen3Match() {
        XCTAssertEqual(ThinkingMarkers.forModel(named: "Qwen3-7B-Instruct"), .qwen3)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "deepseek-r1-distill-llama-8b"), .qwen3)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "QwQ-32B-Preview"), .qwen3)
    }

    func test_forModel_mistralReasoningMatch() {
        XCTAssertEqual(ThinkingMarkers.forModel(named: "Mistral-Small-3.1-Reasoning"), .mistralReasoning)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "Sky-T1-32B-Preview"), .mistralReasoning)
    }

    func test_forModel_phi4Match() {
        XCTAssertEqual(ThinkingMarkers.forModel(named: "phi4-reasoning"), .phi4)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "Phi-4-mini"), .phi4)
    }

    func test_forModel_reflectionMatch() {
        XCTAssertEqual(ThinkingMarkers.forModel(named: "Reflection-Llama-3.1-70B"), .reflection)
    }

    // MARK: - forModel(named:) — case variants

    func test_forModel_caseInsensitive() {
        XCTAssertEqual(ThinkingMarkers.forModel(named: "QWEN3"), .qwen3)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "qwen3"), .qwen3)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "DeepSeek-R1"), .qwen3)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "MISTRAL-small"), .mistralReasoning)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "PHI-4"), .phi4)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "REFLECTION-LLAMA-3.1"), .reflection)
    }

    // MARK: - forModel(named:) — ambiguity precedence

    func test_forModel_reflectionLlamaBeatsGenericLlama() {
        // A bare "llama-3.1" name does not match any known family; only "reflection-llama"
        // triggers the reflection preset.
        XCTAssertNil(ThinkingMarkers.forModel(named: "llama-3.1-8b"))
        XCTAssertEqual(ThinkingMarkers.forModel(named: "Reflection-Llama-3.1-70B"), .reflection)
    }

    func test_forModel_phi4BeatsGenericPhi() {
        // "phi4" and "phi-4" map to .phi4. Generic "phi" or "phi3" is not a known thinking
        // family and must return nil.
        XCTAssertEqual(ThinkingMarkers.forModel(named: "phi4-reasoning"), .phi4)
        XCTAssertEqual(ThinkingMarkers.forModel(named: "phi-4-mini"), .phi4)
        XCTAssertNil(ThinkingMarkers.forModel(named: "phi3-medium"),
            "Only phi4/phi-4 is a thinking model; generic 'phi' variants must not match")
    }

    func test_forModel_reflectionLlamaWinsOverPhi4Substring() {
        // Contrived: a name containing both "reflection-llama" and "phi4" should resolve
        // to .reflection because reflection-llama is checked first (most specific).
        XCTAssertEqual(
            ThinkingMarkers.forModel(named: "reflection-llama-phi4-merged"),
            .reflection,
            "When a name contains both markers, the more specific 'reflection-llama' match wins")

        // Sabotage check: if the precedence were reversed, this would return .phi4.
    }

    // MARK: - forModel(named:) — unknown returns nil

    func test_forModel_unknownReturnsNil() {
        XCTAssertNil(ThinkingMarkers.forModel(named: "gpt-4o"))
        XCTAssertNil(ThinkingMarkers.forModel(named: "claude-3-opus"))
        XCTAssertNil(ThinkingMarkers.forModel(named: "gemma-2-27b"))
        XCTAssertNil(ThinkingMarkers.forModel(named: ""))
    }
}

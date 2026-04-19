import XCTest
@testable import BaseChatFuzz
import BaseChatInference

// MARK: - Shared fixture helper

/// Builds a `RunRecord` with sensible defaults for contract fixtures. Kept
/// private to the contract tests — `DetectorTests` has its own copy tuned for
/// sub-check-by-sub-check unit assertions. Contract fixtures exercise the
/// detector as a whole, so we keep fixture construction visually adjacent to
/// each contract type.
private enum ContractRecord {
    static func make(
        rendered: String = "",
        raw: String = "",
        thinkingRaw: String = "",
        thinkingParts: [String] = [],
        thinkingCompleteCount: Int = 0,
        phase: String = "done",
        totalMs: Double = 0,
        error: String? = nil,
        markers: RunRecord.MarkerSnapshot? = .init(open: "<think>", close: "</think>"),
        userPrompt: String = "what is two plus two?",
        stopReason: String? = "naturalStop"
    ) -> RunRecord {
        RunRecord(
            runId: "contract-fixture",
            ts: "2026-04-19T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: "deadbeef",
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "mock",
                id: "contract-model",
                url: "mem://contract",
                fileSHA256: nil,
                tokenizerHash: nil
            ),
            config: .init(
                seed: 0,
                temperature: 0.0,
                topP: 1.0,
                maxTokens: nil,
                systemPrompt: nil
            ),
            prompt: .init(
                corpusId: "contract",
                mutators: [],
                messages: [.init(role: "user", text: userPrompt)]
            ),
            events: [],
            // `rendered` is deprecated (always a duplicate of `raw` in
            // production). Mirror the two so contract fixtures that set only
            // `rendered:` still exercise detectors that now read `raw`.
            raw: raw.isEmpty ? rendered : raw,
            rendered: rendered.isEmpty ? raw : rendered,
            thinkingRaw: thinkingRaw,
            thinkingParts: thinkingParts,
            thinkingCompleteCount: thinkingCompleteCount,
            templateMarkers: markers,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: nil, totalMs: totalMs, tokensPerSec: nil),
            phase: phase,
            error: error,
            stopReason: stopReason
        )
    }
}

// MARK: - Shared contract assertions

/// Pure assertion helpers invoked from each detector-specific `XCTestCase`.
/// XCTest doesn't cleanly support generic test classes, so we don't try — each
/// contract conformer gets its own concrete test case that delegates here.
enum DetectorContractAsserter {
    static func assertPositive<C: DetectorContract>(
        _ contract: C.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let findings = C.detector.inspect(C.positiveFixture)
        XCTAssertFalse(
            findings.isEmpty,
            "\(C.self) positive fixture must produce at least one finding for detector \(C.detector.id)",
            file: file,
            line: line
        )
    }

    static func assertNegative<C: DetectorContract>(
        _ contract: C.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let findings = C.detector.inspect(C.negativeFixture)
        XCTAssertTrue(
            findings.isEmpty,
            "\(C.self) negative fixture must produce no findings, got: \(findings.map { "\($0.subCheck):\($0.trigger)" })",
            file: file,
            line: line
        )
    }

    /// Boundary fixtures sit on the detector's threshold. Inspecting ten times
    /// in a row must return byte-identical findings — if a detector is
    /// non-deterministic at its boundary, the fuzzer's dedup hash will churn
    /// and the signal-to-noise ratio in the sink collapses.
    static func assertBoundary<C: DetectorContract>(
        _ contract: C.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let first = C.detector.inspect(C.boundaryFixture)
        let firstFingerprints = first.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
        for i in 1..<10 {
            let next = C.detector.inspect(C.boundaryFixture)
            let nextFingerprints = next.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
            XCTAssertEqual(
                firstFingerprints,
                nextFingerprints,
                "\(C.self) boundary fixture produced different findings on run \(i) vs run 0",
                file: file,
                line: line
            )
        }
    }

    static func assertAdversarial<C: DetectorContract>(
        _ contract: C.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let findings = C.detector.inspect(C.adversarialFixture)
        XCTAssertTrue(
            findings.isEmpty,
            "\(C.self) adversarial fixture must not fire, got: \(findings.map { "\($0.subCheck):\($0.trigger)" })",
            file: file,
            line: line
        )
    }
}

// MARK: - ThinkingClassificationDetector contract

enum ThinkingClassificationContract: DetectorContract {
    static var detector: any Detector { ThinkingClassificationDetector() }

    /// Positive: literal `<think>` markers leak into the rendered string —
    /// `visible-text-leak` sub-check must fire.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "Sure! <think>let me think about this</think> the answer is 4.",
            raw: "Sure! <think>let me think about this</think> the answer is 4.",
            thinkingRaw: "let me think about this",
            thinkingParts: ["let me think about this"],
            thinkingCompleteCount: 1
        )
    }

    /// Negative: the backend stripped markers from the stream and surfaced
    /// thinking tokens via structured events. `raw` carries only the
    /// user-visible answer, `thinkingRaw` captures reasoning, and the complete
    /// event balances. Pre-#499 this fixture relied on `rendered` diverging
    /// from `raw` to avoid `visible-text-leak`; detectors now read `raw`
    /// directly, so the fixture must keep markers out of `raw` itself.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            raw: "The answer is 4.",
            thinkingRaw: "two plus two",
            thinkingParts: ["two plus two"],
            thinkingCompleteCount: 1
        )
    }

    /// Boundary: thinking content with exactly one complete event and a normal
    /// phase=done. The `unbalanced-thinking-events` check sits right at the
    /// edge of firing when `thinkingCompleteCount == 0` — we pick the
    /// just-balanced shape so the detector deterministically returns zero
    /// findings every time.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "ok",
            raw: "<think>quick</think>ok",
            thinkingRaw: "quick",
            thinkingParts: ["quick"],
            thinkingCompleteCount: 1,
            phase: "done",
            stopReason: "naturalStop"
        )
    }

    /// Adversarial: the output contains Markdown code-fenced pseudo-tags
    /// (`<thinking>` / `<reasoning>`) that superficially resemble reasoning
    /// markers, plus the user's prompt itself talks about template tokens.
    /// A naive "does rendered mention thinky-looking strings" heuristic would
    /// false-positive here; the detector's correct behaviour is to compare
    /// only against the configured `<think>`/`</think>` marker pair and stay
    /// silent because no literal marker appears.
    static var adversarialFixture: RunRecord {
        let fenced = """
        In most chat templates, a reasoning block is delimited by a pair of tags.
        For example, some backends use `<thinking>` and `</thinking>`; others use
        `<reasoning>` and `</reasoning>`. The exact spelling is model-specific.
        """
        return ContractRecord.make(
            rendered: fenced,
            raw: fenced,
            thinkingRaw: "",
            thinkingParts: [],
            thinkingCompleteCount: 0,
            userPrompt: "Which tags delimit reasoning blocks in chat templates?"
        )
    }
}

final class ThinkingClassificationContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(ThinkingClassificationContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(ThinkingClassificationContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(ThinkingClassificationContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(ThinkingClassificationContract.self)
    }
}

// MARK: - LoopingDetector contract

enum LoopingContract: DetectorContract {
    static var detector: any Detector { LoopingDetector() }

    /// Positive: `"repeat this phrase. "` x 30 — a clear 3x/2x loop on the
    /// rendered stream. `RepetitionDetector.looksLikeLooping` trips on this.
    static var positiveFixture: RunRecord {
        let looped = String(repeating: "repeat this phrase. ", count: 30)
        return ContractRecord.make(rendered: looped)
    }

    /// Negative: varied English prose with no repeated units.
    static var negativeFixture: RunRecord {
        let prose = """
        A curious fox padded through the damp undergrowth as dawn crept over \
        the ridge. Somewhere beyond the treeline, a stream muttered to itself. \
        The kettle on the kitchen stove began its slow, persuasive whistle while \
        a distant train dragged its long shadow across the valley floor.
        """
        return ContractRecord.make(rendered: prose)
    }

    /// Boundary: the shortest rendered string that still trips both the 100
    /// character floor and `looksLikeLooping`'s 50-char 2x detection. We pick
    /// a 50-character unit repeated twice (100 chars total) — the minimum
    /// size the detector accepts.
    static var boundaryFixture: RunRecord {
        let unit = "the quick brown fox jumps over the lazy dogs today" // 50 chars
        precondition(unit.count == 50, "boundary unit must stay at 50 chars")
        let looped = unit + unit
        return ContractRecord.make(rendered: looped)
    }

    /// Adversarial: a genuine Markdown bullet list where each bullet is
    /// similar-looking (starts with `- `, short verb-noun) but no two bullets
    /// are literal repeats of each other. A naive substring-compare loop
    /// detector would fire here; `looksLikeLooping` should not.
    static var adversarialFixture: RunRecord {
        let bullets = """
        Here are the steps:
        - Install the package.
        - Configure the backend.
        - Load a model.
        - Send a prompt.
        - Stream the response.
        - Render the output.
        - Cancel on user stop.
        - Persist the transcript.
        - Export the history.
        - Clean up resources.
        """
        return ContractRecord.make(rendered: bullets)
    }
}

final class LoopingContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(LoopingContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(LoopingContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(LoopingContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(LoopingContract.self)
    }
}

// MARK: - EmptyOutputAfterWorkDetector contract

enum EmptyOutputAfterWorkContract: DetectorContract {
    static var detector: any Detector { EmptyOutputAfterWorkDetector() }

    /// Positive: 10s elapsed, phase=done, no visible content, no thinking.
    /// The canonical "backend swallowed the stream" shape.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            thinkingRaw: "",
            phase: "done",
            totalMs: 10_000
        )
    }

    /// Negative: 10s elapsed but the model produced an answer — nothing to
    /// flag. The detector also sees no `error`, phase=done, stopReason=natural.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            rendered: "Yes — here is the answer you asked for.",
            raw: "Yes — here is the answer you asked for.",
            thinkingRaw: "",
            phase: "done",
            totalMs: 10_000
        )
    }

    /// Boundary: exactly at the 8,000 ms threshold. The guard is
    /// `totalMs >= workThresholdMs`, so 8_000.0 MUST fire; determinism means
    /// ten inspections return identical findings.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            thinkingRaw: "",
            phase: "done",
            totalMs: 8_000
        )
    }

    /// Adversarial: legitimate instant-refusal case — the model replied with
    /// an empty string very fast (<1s). This is common with strict safety
    /// filters that produce `""` for disallowed prompts. A naive "empty
    /// output" detector would fire; this one gates on `>=8s elapsed` for
    /// exactly this reason.
    static var adversarialFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            thinkingRaw: "",
            phase: "done",
            totalMs: 150,
            userPrompt: "please describe a forbidden topic"
        )
    }
}

final class EmptyOutputAfterWorkContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(EmptyOutputAfterWorkContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(EmptyOutputAfterWorkContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(EmptyOutputAfterWorkContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(EmptyOutputAfterWorkContract.self)
    }
}

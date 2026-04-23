import Foundation

/// Inspired by 0d3c206 — the `hasVisibleContent` bug where a message with
/// only thinking content was treated as "has content" and the empty visible
/// string was rendered as a blank bubble. Catches the inverse of the
/// `EmptyOutputAfterWorkDetector`: the model *did* produce raw tokens and
/// *did* produce thinking, but the visible rendering is empty.
///
/// Today's `rendered` field holds only the user-visible portion of the stream
/// (no `<think>` blocks). It is doc-comment-deprecated in favour of a future
/// "real UI-transform rendering" path; until that path ships, `rendered` is
/// the only field that tracks the visible-only output, so this detector
/// continues to read it rather than `raw` (which includes thinking tokens).
///
/// Ships at `.flaky` severity. Promotion to `.confirmed` requires the
/// calibration corpus + FP/TP gating planned in W2.C phase 2.
public struct EmptyVisibleAfterThinkDetector: Detector {
    public let id = "empty-visible-after-think"
    public let humanName = "Empty visible output after thinking"
    public let inspiredBy = "0d3c206 — hasVisibleContent bug"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        guard r.phase == "done",
              !r.raw.isEmpty,
              !r.thinkingRaw.isEmpty,
              r.rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }

        return [Finding(
            detectorId: id,
            subCheck: "visible-empty",
            severity: .flaky,
            trigger: "thinking=\(r.thinkingRaw.count)B rendered=empty",
            modelId: r.model.id
        )]
    }
}

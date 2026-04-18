import Foundation

/// Inspired by df94418 (`<think>` blocks leaking into UI) and the failure modes
/// enabled by PR #476's structured thinking events: content can now be
/// misclassified between `.text` and `.thinking` parts in either direction.
public struct ThinkingClassificationDetector: Detector {
    public let id = "thinking-classification"
    public let humanName = "Thinking classification"
    public let inspiredBy = "df94418, PR #476"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        var findings: [Finding] = []
        let markers = r.templateMarkers ?? .init(open: "<think>", close: "</think>")

        // 1. Visible-text leak: literal markers appear in the user-visible string.
        if r.rendered.contains(markers.open) || r.rendered.contains(markers.close) {
            findings.append(.init(
                detectorId: id,
                subCheck: "visible-text-leak",
                severity: .flaky,
                trigger: extractContext(r.rendered, around: markers.open),
                modelId: r.model.id
            ))
        }

        // 2. Misclassified-as-text: open marker appears in raw stream but no
        //    structured thinking events were emitted (parser failed; reasoning
        //    fell into `.text`).
        if r.raw.contains(markers.open) && r.thinkingRaw.isEmpty {
            findings.append(.init(
                detectorId: id,
                subCheck: "misclassified-as-text",
                severity: .flaky,
                trigger: extractContext(r.raw, around: markers.open),
                modelId: r.model.id
            ))
        }

        // 3. Orphan thinking-complete: complete event fired without any thinking tokens.
        if r.thinkingCompleteCount > 0 && r.thinkingRaw.isEmpty {
            findings.append(.init(
                detectorId: id,
                subCheck: "orphan-thinking-complete",
                severity: .flaky,
                trigger: "thinkingCompleteCount=\(r.thinkingCompleteCount), thinkingRaw=empty",
                modelId: r.model.id
            ))
        }

        // 4. Unbalanced events: thinking emitted but never closed cleanly,
        //    yet the stream completed normally.
        if !r.thinkingRaw.isEmpty && r.thinkingCompleteCount == 0 && r.phase == "done" {
            findings.append(.init(
                detectorId: id,
                subCheck: "unbalanced-thinking-events",
                severity: .flaky,
                trigger: "thinkingRaw=\(r.thinkingRaw.prefix(80))…",
                modelId: r.model.id
            ))
        }

        return findings
    }

    private func extractContext(_ s: String, around needle: String, span: Int = 60) -> String {
        guard let range = s.range(of: needle) else { return String(s.prefix(120)) }
        let start = s.index(range.lowerBound, offsetBy: -span, limitedBy: s.startIndex) ?? s.startIndex
        let end = s.index(range.upperBound, offsetBy: span, limitedBy: s.endIndex) ?? s.endIndex
        return "…\(s[start..<end])…"
    }
}


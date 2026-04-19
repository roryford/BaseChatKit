import Foundation
import BaseChatInference

/// Inspired by qwen3.5:4b looping inside `<think>` blocks until `maxOutputTokens`
/// exhausts. Runs `RepetitionDetector.looksLikeLooping` over both the visible
/// stream and the thinking buffer separately — the thinking-side loop leaves
/// `raw` empty, which a raw-only check would miss.
public struct LoopingDetector: Detector {
    public let id = "looping"
    public let humanName = "Repetition / loop"
    public let inspiredBy = "PR #476 thinking-token work + longstanding looping-on-repetitive-prompts observation"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        var findings: [Finding] = []

        // Sub-check id stays `rendered-loop` for dedup stability across the
        // existing on-disk sink — the name predates `rendered`'s deprecation.
        if r.raw.count >= 100, RepetitionDetector.looksLikeLooping(r.raw) {
            findings.append(.init(
                detectorId: id,
                subCheck: "rendered-loop",
                severity: .flaky,
                trigger: String(r.raw.suffix(120)),
                modelId: r.model.id
            ))
        }

        if r.thinkingRaw.count >= 100, RepetitionDetector.looksLikeLooping(r.thinkingRaw) {
            findings.append(.init(
                detectorId: id,
                subCheck: "thinking-loop",
                severity: .flaky,
                trigger: String(r.thinkingRaw.suffix(120)),
                modelId: r.model.id
            ))
        }

        return findings
    }
}

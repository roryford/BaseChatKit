import Foundation
import BaseChatInference

/// Inspired by qwen3.5:4b looping inside `<think>` blocks until `maxOutputTokens`
/// exhausts. Runs `RepetitionDetector.looksLikeLooping` over both the visible
/// stream and the thinking buffer separately — the thinking-side loop leaves
/// `rendered` empty, which a rendered-only check would miss.
public struct LoopingDetector: Detector {
    public let id = "looping"
    public let humanName = "Repetition / loop"
    public let inspiredBy = "PR #476 thinking-token work + longstanding looping-on-repetitive-prompts observation"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        var findings: [Finding] = []

        if r.rendered.count >= 100, RepetitionDetector.looksLikeLooping(r.rendered) {
            findings.append(.init(
                detectorId: id,
                subCheck: "rendered-loop",
                severity: .flaky,
                trigger: String(r.rendered.suffix(120)),
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

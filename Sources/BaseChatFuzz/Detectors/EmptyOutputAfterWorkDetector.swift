import Foundation

/// Inspired by the OllamaBackend `thinking`-field drop discovered while smoking
/// the harness against qwen3.5:4b: the model spent 80+ seconds reasoning, the
/// backend swallowed every byte, and the user saw an empty assistant bubble.
///
/// Fires when generation took non-trivial time, completed cleanly, but produced
/// no visible content AND no thinking content. Either the backend dropped the
/// stream, the model produced nothing, or a stop condition fired silently.
public struct EmptyOutputAfterWorkDetector: Detector {
    public let id = "empty-output-after-work"
    public let humanName = "Empty output after non-trivial work"
    public let inspiredBy = "OllamaBackend.extractToken drops `thinking` field (qwen3.5:4b smoke)"

    /// Time threshold above which a clean-but-empty completion is suspicious.
    public let workThresholdMs: Double

    public init(workThresholdMs: Double = 3_000) {
        self.workThresholdMs = workThresholdMs
    }

    public func inspect(_ r: RunRecord) -> [Finding] {
        guard r.phase == "done",
              r.error == nil,
              r.timing.totalMs >= workThresholdMs,
              r.rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              r.thinkingRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }

        let trigger = "totalMs=\(Int(r.timing.totalMs)) raw.empty thinkingRaw.empty error=nil"
        return [Finding(
            detectorId: id,
            subCheck: "silent-empty",
            severity: .flaky,
            trigger: trigger,
            modelId: r.model.id
        )]
    }
}

import Foundation

public actor TerminalReporter {

    private let quiet: Bool
    private var lastFlush: ContinuousClock.Instant = .now

    public init(quiet: Bool) {
        self.quiet = quiet
    }

    public func preflight(backend: String, model: String, detectors: [String]) {
        guard !quiet else { return }
        print("─── fuzz-chat preflight ───")
        print("  backend:   \(backend)")
        print("  model:     \(model)")
        print("  detectors: \(detectors.joined(separator: ", "))")
        print("───────────────────────────")
    }

    public func iterationStart(iter: Int, model: String, temp: Float, totalFindings: Int) {
        guard !quiet else { return }
        let line = String(format: "[iter %d] %@ temp=%.1f findings=%d", iter, model, temp, totalFindings)
        FileHandle.standardOutput.write(Data("\r\u{1B}[K\(line)".utf8))
    }

    public func finding(_ f: Finding) {
        // Always print finding events, even in quiet mode
        let trigger = f.trigger.replacingOccurrences(of: "\n", with: " ").prefix(80)
        print("\n  ↑ \(f.severity.rawValue) [\(f.detectorId)/\(f.subCheck)] hash=\(f.hash) :: \(trigger)")
    }

    public func error(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }

    public func finalSummary(report: FuzzReport) {
        guard !quiet else { return }
        let perDetectorLines = report.perDetectorFlagRate
            .sorted { $0.value > $1.value }
            .map { String(format: "    %@   %.2f%% flag rate", $0.key, $0.value * 100) }
            .joined(separator: "\n")
        print("\n━━━ FUZZ SUMMARY ━━━")
        print("  Iterations:      \(report.totalRuns)")
        print("  Unique findings: \(report.dedupedCount)")
        if !perDetectorLines.isEmpty {
            print("  Detectors:")
            print(perDetectorLines)
        }
        print("  Triage:          open tmp/fuzz/INDEX.md")
        print("━━━━━━━━━━━━━━━━━━━━")
    }
}

import Foundation

/// Writes `RunRecord`s and `Finding`s to disk, deduping per finding hash and
/// regenerating `INDEX.md` on every flush.
public actor FindingsSink {

    private let outputDir: URL
    private var index: [String: IndexRow] = [:]
    private var totalRuns = 0

    private struct IndexRow: Codable {
        var finding: Finding
        var modelId: String
        var lastSeen: String
    }

    public init(outputDir: URL) {
        self.outputDir = outputDir
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: outputDir.appendingPathComponent("findings", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Load existing index synchronously; safe because nothing else holds this actor yet.
        let indexURL = outputDir.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL),
           let rows = try? JSONDecoder().decode([IndexRow].self, from: data) {
            self.index = Dictionary(uniqueKeysWithValues: rows.map { ($0.finding.hash, $0) })
        }
    }

    /// Increments `totalRuns` and rewrites `INDEX.md` so empty runs leave a
    /// visible trace ("12 total runs, 0 unique findings").
    public func noteEmptyRun() {
        totalRuns += 1
        writeIndex()
    }

    public func recordRun(_ record: RunRecord, findings: [Finding]) {
        totalRuns += 1
        for finding in findings {
            var stored = finding
            if let prior = index[finding.hash] {
                stored.count = prior.finding.count + 1
                stored.firstSeen = prior.finding.firstSeen
            }
            let dir = outputDir
                .appendingPathComponent("findings", isDirectory: true)
                .appendingPathComponent(finding.detectorId, isDirectory: true)
                .appendingPathComponent(finding.hash, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let recordURL = dir.appendingPathComponent("record.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(record) {
                try? data.write(to: recordURL)
            }

            let summary = "\(stored.severity.rawValue) | \(stored.detectorId)/\(stored.subCheck) | \(stored.modelId) | count=\(stored.count)\nTrigger: \(stored.trigger)\n"
            try? summary.write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

            let reproCmd = "swift run fuzz-chat -- --replay \(stored.hash)\n"
            try? reproCmd.write(to: dir.appendingPathComponent("repro.sh"), atomically: true, encoding: .utf8)

            index[finding.hash] = IndexRow(finding: stored, modelId: record.model.id, lastSeen: ISO8601DateFormatter().string(from: Date()))
        }
        writeIndex()
    }

    public func snapshot() -> (totalRuns: Int, findings: [Finding]) {
        (totalRuns, index.values.map { $0.finding })
    }

    private func writeIndex() {
        let rows = index.values.sorted { ($0.finding.severity, $0.finding.count) > ($1.finding.severity, $1.finding.count) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Array(rows)) {
            try? data.write(to: outputDir.appendingPathComponent("index.json"))
        }

        var md = "# Fuzz findings\n\n"
        md += "_\(totalRuns) total runs, \(rows.count) unique findings._\n\n"
        md += "| Severity | Detector / sub-check | Model | Hash | First seen | Count | Trigger | Replay |\n"
        md += "|---|---|---|---|---|---|---|---|\n"
        for row in rows {
            let f = row.finding
            let trigger = f.trigger.replacingOccurrences(of: "|", with: "\\|").prefix(80)
            md += "| \(f.severity.rawValue) | \(f.detectorId) / \(f.subCheck) | \(row.modelId) | `\(f.hash)` | \(f.firstSeen) | \(f.count) | \(trigger) | `swift run fuzz-chat -- --replay \(f.hash)` |\n"
        }
        try? md.write(to: outputDir.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)
    }
}

private func > <A: Comparable, B: Comparable>(lhs: (A, B), rhs: (A, B)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
    return lhs.1 > rhs.1
}

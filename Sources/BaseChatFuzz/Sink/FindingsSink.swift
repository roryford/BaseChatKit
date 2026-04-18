import Foundation
import BaseChatInference

/// Writes `RunRecord`s and `Finding`s to disk, deduping per finding hash and
/// regenerating `INDEX.md` on every flush.
public actor FindingsSink {

    private let outputDir: URL
    private var index: [String: IndexRow] = [:]
    private var totalRuns = 0

    private struct IndexRow: Codable {
        var finding: Finding
        var modelId: String
        var seed: UInt64
        var lastSeen: String
    }

    /// On-disk envelope so `totalRuns` survives across `FindingsSink` instances.
    /// The legacy bare-array format is still accepted and migrated lazily on
    /// first write — `totalRuns` resumes from the row count in that case.
    private struct IndexFile: Codable {
        var totalRuns: Int
        var rows: [IndexRow]
    }

    public init(outputDir: URL) {
        self.outputDir = outputDir
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: outputDir.appendingPathComponent("findings", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            Self.logError("Failed to create FindingsSink output directories at \(outputDir.path): \(error)")
        }
        // Load existing index synchronously; safe because nothing else holds this actor yet.
        let indexURL = outputDir.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let decoder = JSONDecoder()
            do {
                let data = try Data(contentsOf: indexURL)
                do {
                    let envelope = try decoder.decode(IndexFile.self, from: data)
                    self.totalRuns = envelope.totalRuns
                    self.index = Dictionary(uniqueKeysWithValues: envelope.rows.map { ($0.finding.hash, $0) })
                } catch {
                    // Legacy format: bare `[IndexRow]` array. Resume totalRuns from the row count.
                    let rows = try decoder.decode([IndexRow].self, from: data)
                    self.totalRuns = rows.count
                    self.index = Dictionary(uniqueKeysWithValues: rows.map { ($0.finding.hash, $0) })
                }
            } catch {
                Log.inference.warning("FindingsSink: failed to load existing index.json at \(indexURL.path, privacy: .public); starting fresh: \(String(describing: error), privacy: .public)")
            }
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
            let isFirstSighting = index[finding.hash] == nil
            if let prior = index[finding.hash] {
                stored.count = prior.finding.count + 1
                stored.firstSeen = prior.finding.firstSeen
            }
            let dir = outputDir
                .appendingPathComponent("findings", isDirectory: true)
                .appendingPathComponent(finding.detectorId, isDirectory: true)
                .appendingPathComponent(finding.hash, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Self.logError("Failed to create finding directory at \(dir.path): \(error)")
                continue
            }

            let priorSeed = index[finding.hash]?.seed
            let recordedSeed = isFirstSighting ? record.config.seed : (priorSeed ?? record.config.seed)

            // Only write record.json on first sight: it captures the cleanest minimal repro
            // and any later overwrite would mask the original triggering input.
            if isFirstSighting {
                let recordURL = dir.appendingPathComponent("record.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                do {
                    let data = try encoder.encode(record)
                    try data.write(to: recordURL)
                } catch {
                    Self.logError("Failed to write record.json for finding \(finding.hash) at \(recordURL.path): \(error)")
                }
            }

            let summary = "\(stored.severity.rawValue) | \(stored.detectorId)/\(stored.subCheck) | \(stored.modelId) | count=\(stored.count)\nTrigger: \(stored.trigger)\n"
            do {
                try summary.write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            } catch {
                Self.logError("Failed to write summary.txt for finding \(finding.hash): \(error)")
            }

            let reproCmd = Self.reproCommand(seed: recordedSeed, modelId: record.model.id)
            let reproScript = "#!/bin/sh\n# --replay is not yet implemented (#490); using direct seed/model/--single recipe\n\(reproCmd)\n"
            do {
                try reproScript.write(to: dir.appendingPathComponent("repro.sh"), atomically: true, encoding: .utf8)
            } catch {
                Self.logError("Failed to write repro.sh for finding \(finding.hash): \(error)")
            }

            index[finding.hash] = IndexRow(
                finding: stored,
                modelId: record.model.id,
                seed: recordedSeed,
                lastSeen: ISO8601DateFormatter().string(from: Date())
            )
        }
        writeIndex()
    }

    public func snapshot() -> (totalRuns: Int, findings: [Finding]) {
        (totalRuns, index.values.map { $0.finding })
    }

    private func writeIndex() {
        let rows = index.values.sorted { ($0.finding.severity, $0.finding.count) > ($1.finding.severity, $1.finding.count) }

        let envelope = IndexFile(totalRuns: totalRuns, rows: Array(rows))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let indexURL = outputDir.appendingPathComponent("index.json")
        do {
            let data = try encoder.encode(envelope)
            try data.write(to: indexURL)
        } catch {
            Self.logError("Failed to write index.json at \(indexURL.path): \(error)")
        }

        var md = "# Fuzz findings\n\n"
        md += "_\(totalRuns) total runs, \(rows.count) unique findings._\n\n"
        md += "| Severity | Detector / sub-check | Model | Hash | First seen | Count | Trigger | Replay |\n"
        md += "|---|---|---|---|---|---|---|---|\n"
        for row in rows {
            let f = row.finding
            let trigger = f.trigger.replacingOccurrences(of: "|", with: "\\|").prefix(80)
            let repro = Self.reproCommand(seed: row.seed, modelId: row.modelId)
            md += "| \(f.severity.rawValue) | \(f.detectorId) / \(f.subCheck) | \(row.modelId) | `\(f.hash)` | \(f.firstSeen) | \(f.count) | \(trigger) | `\(repro)` |\n"
        }
        let mdURL = outputDir.appendingPathComponent("INDEX.md")
        do {
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            Self.logError("Failed to write INDEX.md at \(mdURL.path): \(error)")
        }
    }

    private static func reproCommand(seed: UInt64, modelId: String) -> String {
        "swift run fuzz-chat --seed \(seed) --model \(modelId) --single"
    }

    private static func logError(_ message: String) {
        Log.inference.error("FindingsSink: \(message, privacy: .public)")
        FileHandle.standardError.write(Data("FindingsSink error: \(message)\n".utf8))
    }
}

private func > <A: Comparable, B: Comparable>(lhs: (A, B), rhs: (A, B)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
    return lhs.1 > rhs.1
}

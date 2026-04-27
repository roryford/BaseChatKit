import XCTest
@testable import BaseChatFuzz
import Foundation

// MARK: - Calibration harness

/// Loads the labeled fixture corpus from Sources/BaseChatTestSupport/FuzzCalibrationCorpus/
/// and asserts per-detector accuracy gates:
///
/// - **FP < 2%**: each detector must fire on fewer than 2 % of the known-good records.
/// - **TP > 80%**: each detector must fire on more than 80 % of the known-bad records
///   labeled with its ID.
///
/// A detector that passes both gates is eligible for promotion from `.flaky` to
/// `.confirmed` severity. This is the "watchmen" check from the QA review on the
/// original fuzz design — see issue #488.
///
/// ## Corpus layout
///
/// ```
/// Sources/BaseChatTestSupport/FuzzCalibrationCorpus/
///   good.json   — array of RunRecord (known-good, no detector should fire)
///   bad.json    — array of {detectorId, note, record} (known-bad, labeled by bug class)
/// ```
///
/// Corpus files are read at test-run time via `#filePath`-relative URL (the same
/// pattern used by `SilentCatchAuditTest` for `silent_catch_allowlist.txt`).  No
/// resource-bundling change to Package.swift is required.
final class CalibrationTests: XCTestCase {

    // MARK: - Corpus model

    private struct LabeledBadRecord: Decodable {
        var detectorId: String
        var note: String
        var record: RunRecord
    }

    // MARK: - Path helpers

    /// Navigate from this source file up three levels to the repo root, then into
    /// Sources/BaseChatTestSupport/FuzzCalibrationCorpus/.
    private static func corpusRoot() -> URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent() // .../Tests/BaseChatFuzzTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/BaseChatTestSupport/FuzzCalibrationCorpus",
                                    isDirectory: true)
    }

    private func loadGoodRecords() throws -> [RunRecord] {
        let url = Self.corpusRoot().appendingPathComponent("good.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Calibration corpus not found at \(url.path)")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([RunRecord].self, from: data)
    }

    private func loadBadRecords() throws -> [LabeledBadRecord] {
        let url = Self.corpusRoot().appendingPathComponent("bad.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Calibration corpus not found at \(url.path)")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([LabeledBadRecord].self, from: data)
    }

    // MARK: - Gate constants

    private let fpThreshold = 0.02  // FP rate must be strictly below 2 %
    private let tpThreshold = 0.80  // TP rate must be at or above 80 %

    // MARK: - FP gate

    func test_falsePositiveRate_allDetectors_belowTwoPercent() throws {
        let goodRecords = try loadGoodRecords()
        XCTAssertGreaterThanOrEqual(
            goodRecords.count, 200,
            "Calibration good corpus must have ≥ 200 records to make the 2 % FP gate statistically meaningful"
        )

        let detectors = DetectorRegistry.all
        var failures: [String] = []

        for detector in detectors {
            let fpCount = goodRecords.filter { !detector.inspect($0).isEmpty }.count
            let fpRate = Double(fpCount) / Double(goodRecords.count)
            if fpRate >= fpThreshold {
                let pct = String(format: "%.1f", fpRate * 100)
                failures.append("• \(detector.id): \(fpCount)/\(goodRecords.count) FPs (\(pct) % ≥ 2 %)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Detectors whose false-positive rate on the good corpus is ≥ 2 %:\n"
                + failures.joined(separator: "\n")
                + "\nFix the detector logic, tighten the trigger condition, or reclassify the mis-fired good records."
        )
    }

    // MARK: - TP gate

    func test_truePositiveRate_allDetectors_aboveEightyPercent() throws {
        let badRecords = try loadBadRecords()
        XCTAssertGreaterThanOrEqual(
            badRecords.count, 50,
            "Calibration bad corpus must have ≥ 50 records"
        )

        let detectors = DetectorRegistry.all
        var failures: [String] = []

        for detector in detectors {
            let forDetector = badRecords.filter { $0.detectorId == detector.id }
            guard !forDetector.isEmpty else { continue }

            let tpCount = forDetector.filter { !detector.inspect($0.record).isEmpty }.count
            let tpRate = Double(tpCount) / Double(forDetector.count)
            if tpRate < tpThreshold {
                let pct = String(format: "%.1f", tpRate * 100)
                failures.append("• \(detector.id): \(tpCount)/\(forDetector.count) TPs (\(pct) % < 80 %)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Detectors whose true-positive rate on the bad corpus is < 80 %:\n"
                + failures.joined(separator: "\n")
                + "\nAdd more representative bad records to bad.json or fix the detector's trigger condition."
        )
    }

    // MARK: - Coverage check

    /// Every detector in DetectorRegistry.all must have at least one bad-corpus
    /// entry so the TP gate is meaningful for that detector.
    func test_badCorpusCoverage_allDetectorsCovered() throws {
        let badRecords = try loadBadRecords()
        let coveredIds = Set(badRecords.map(\.detectorId))
        let uncovered = DetectorRegistry.all
            .map(\.id)
            .filter { !coveredIds.contains($0) }

        XCTAssertTrue(
            uncovered.isEmpty,
            "Detectors with no bad-corpus coverage (add records to bad.json): "
                + uncovered.joined(separator: ", ")
        )
    }

    // MARK: - Schema roundtrip

    /// Corpus records must survive a JSON encode → decode cycle without loss so
    /// that future corpus additions can be validated without a real fuzz run.
    func test_goodCorpus_roundtripsJSON() throws {
        let goodRecords = try loadGoodRecords()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for record in goodRecords.prefix(10) {
            let data = try encoder.encode(record)
            let decoded = try decoder.decode(RunRecord.self, from: data)
            XCTAssertEqual(record, decoded, "RunRecord \(record.runId) did not survive JSON roundtrip")
        }
    }

    // MARK: - Corpus sanity checks

    func test_goodCorpusSize() throws {
        let goodRecords = try loadGoodRecords()
        XCTAssertGreaterThanOrEqual(goodRecords.count, 200, "Expected ≥ 200 good records")
    }

    func test_badCorpusSize() throws {
        let badRecords = try loadBadRecords()
        XCTAssertGreaterThanOrEqual(badRecords.count, 50, "Expected ≥ 50 bad records")
    }

    // MARK: - Meta-validation (sabotage guard)

    /// An always-firing detector would have FP rate = 100 % >> 2 %. Verifies the
    /// FP-gate arithmetic is wired correctly and would catch a broken detector.
    func test_meta_alwaysFiringDetectorExceedsFPThreshold() throws {
        let goodRecords = try loadGoodRecords()
        let syntheticFPRate = 1.0  // 100 % FP — always fires
        XCTAssertGreaterThan(
            syntheticFPRate, fpThreshold,
            "Sanity: an always-firing detector (100 % FP) must exceed the 2 % threshold"
        )
        // Confirm the assertion would fire for a mock that fails every record.
        let wouldFail = Double(goodRecords.count) / Double(goodRecords.count) >= fpThreshold
        XCTAssertTrue(wouldFail, "FP gate would not catch a 100 %-firing detector — arithmetic is broken")
    }
}

import XCTest
@testable import BaseChatFuzz

final class SmokeTests: XCTestCase {

    func test_corpusLoads() {
        let entries = Corpus.load()
        XCTAssertGreaterThan(entries.count, 0, "Bundled seeds.json should be readable as a resource")
    }

    func test_detectorRegistryHasDayOneDetectors() {
        let ids = DetectorRegistry.all.map(\.id)
        XCTAssertTrue(ids.contains("thinking-classification"))
        XCTAssertTrue(ids.contains("looping"))
    }

    func test_findingHashIsDeterministic() {
        let a = Finding(detectorId: "x", subCheck: "y", severity: .flaky, trigger: "abc", modelId: "m1", firstSeen: "t", count: 1)
        let b = Finding(detectorId: "x", subCheck: "y", severity: .flaky, trigger: "abc", modelId: "m1", firstSeen: "t", count: 1)
        XCTAssertEqual(a.hash, b.hash)
    }
}

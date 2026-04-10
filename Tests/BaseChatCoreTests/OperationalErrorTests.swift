import XCTest
@testable import BaseChatCore

final class OperationalErrorTests: XCTestCase {

    // Exhaustive case coverage — if a case is added, this array drives
    // all the per-case assertions.
    private var allCases: [OperationalError] {
        [
            .modelFileDeletionFailed(URL(fileURLWithPath: "/tmp/model.gguf"), reason: "EPERM"),
            .benchmarkCacheUnavailable(reason: "store corrupt"),
            .titleGenerationFailed(sessionID: UUID(), reason: "backend offline"),
        ]
    }

    func test_localizedDescription_isNonEmptyForEveryCase() {
        for error in allCases {
            XCTAssertFalse(
                error.localizedDescription.isEmpty,
                "localizedDescription must be non-empty for \(error)"
            )
        }
    }

    func test_category_isNonEmptyForEveryCase() {
        for error in allCases {
            XCTAssertFalse(error.category.isEmpty, "category must be non-empty for \(error)")
        }
    }

    func test_modelFileDeletionFailed_descriptionIncludesFileName() {
        let error = OperationalError.modelFileDeletionFailed(
            URL(fileURLWithPath: "/var/models/mistral-7b.gguf"),
            reason: "Permission denied"
        )
        XCTAssertTrue(error.localizedDescription.contains("mistral-7b.gguf"))
        XCTAssertTrue(error.localizedDescription.contains("Permission denied"))
    }

    func test_benchmarkCacheUnavailable_descriptionIncludesReason() {
        let error = OperationalError.benchmarkCacheUnavailable(reason: "disk full")
        XCTAssertTrue(error.localizedDescription.contains("disk full"))
    }

    func test_titleGenerationFailed_descriptionIncludesReason() {
        let error = OperationalError.titleGenerationFailed(sessionID: UUID(), reason: "429 Too Many Requests")
        XCTAssertTrue(error.localizedDescription.contains("429 Too Many Requests"))
    }

    func test_equatable_sameCasesAreEqual() {
        let url = URL(fileURLWithPath: "/a/b.gguf")
        XCTAssertEqual(
            OperationalError.modelFileDeletionFailed(url, reason: "X"),
            OperationalError.modelFileDeletionFailed(url, reason: "X")
        )
    }

    func test_equatable_differentReasonsAreNotEqual() {
        let url = URL(fileURLWithPath: "/a/b.gguf")
        XCTAssertNotEqual(
            OperationalError.modelFileDeletionFailed(url, reason: "A"),
            OperationalError.modelFileDeletionFailed(url, reason: "B")
        )
    }

    func test_operationalWarning_wrapsErrorWithStableIdentity() {
        let error = OperationalError.benchmarkCacheUnavailable(reason: "boom")
        let id = UUID()
        let warning = OperationalWarning(id: id, error: error)
        XCTAssertEqual(warning.id, id)
        XCTAssertEqual(warning.error, error)
    }
}

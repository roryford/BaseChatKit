import XCTest
@testable import BaseChatCore

final class DownloadableModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CuratedModel.all = [
            CuratedModel(
                id: "test-phi",
                displayName: "Phi-3.1 Mini Q4",
                fileName: "phi-3.1-mini-q4.gguf",
                repoID: "bartowski/Phi-3.1-mini-4k-instruct-GGUF",
                modelType: .gguf,
                approximateSizeBytes: 2_200_000_000,
                recommendedFor: [.small, .medium, .large, .xlarge],
                contextSize: 4096,
                promptTemplate: .phi,
                description: "Phi-3.1 Mini 4-bit quantized model"
            )
        ]
    }

    override func tearDown() {
        CuratedModel.all = []
        super.tearDown()
    }

    // MARK: - Init from CuratedModel

    func test_initFromCuratedModel_setsAllProperties() {
        // Safe to force-unwrap: curated list is non-empty by design.
        // swiftlint:disable:next force_unwrapping
        let curated = CuratedModel.all.first!
        let model = DownloadableModel(from: curated)

        XCTAssertEqual(model.repoID, curated.repoID)
        XCTAssertEqual(model.fileName, curated.fileName)
        XCTAssertEqual(model.displayName, curated.displayName)
        XCTAssertEqual(model.modelType, curated.modelType)
        XCTAssertEqual(model.sizeBytes, curated.approximateSizeBytes)
        XCTAssertNil(model.downloads, "Curated models should have nil downloads count")
        XCTAssertTrue(model.isCurated, "Model from curated source should be marked curated")
        XCTAssertEqual(model.promptTemplate, curated.promptTemplate)
        XCTAssertEqual(model.description, curated.description)
    }

    func test_initFromCuratedModel_idFormat() {
        // Safe to force-unwrap: curated list is non-empty by design.
        // swiftlint:disable:next force_unwrapping
        let curated = CuratedModel.all.first!
        let model = DownloadableModel(from: curated)

        let expectedID = "\(curated.repoID)/\(curated.fileName)"
        XCTAssertEqual(model.id, expectedID, "ID should be repoID/fileName")

        // Verify the ID contains exactly one separator between repo and file.
        let components = model.id.components(separatedBy: "/")
        XCTAssertGreaterThanOrEqual(
            components.count, 3,
            "ID should have at least namespace/repo/fileName parts"
        )
    }

    // MARK: - Size Formatting

    func test_sizeFormatted_formatsCorrectly() {
        let model = DownloadableModel(
            repoID: "test/repo",
            fileName: "test.gguf",
            displayName: "Test",
            modelType: .gguf,
            sizeBytes: 4_100_000_000
        )

        let formatted = model.sizeFormatted
        XCTAssertFalse(formatted.isEmpty, "Formatted size should not be empty")
        // ByteCountFormatter with .file style should produce something like "4.1 GB".
        XCTAssertTrue(
            formatted.contains("GB") || formatted.contains("Go"),
            "4.1 billion bytes should format as GB (got: \(formatted))"
        )
    }

    // MARK: - Memberwise Init Defaults

    func test_memberwise_setsIsCuratedFalse() {
        let model = DownloadableModel(
            repoID: "test/repo",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1_000_000
        )

        XCTAssertFalse(model.isCurated, "Memberwise init should default isCurated to false")
        XCTAssertNil(model.downloads, "Memberwise init should default downloads to nil")
        XCTAssertNil(model.promptTemplate, "Memberwise init should default promptTemplate to nil")
        XCTAssertNil(model.description, "Memberwise init should default description to nil")
    }
}

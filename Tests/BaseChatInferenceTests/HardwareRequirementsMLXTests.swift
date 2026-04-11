import XCTest
@testable import BaseChatTestSupport

final class HardwareRequirementsMLXTests: XCTestCase {

    private var tempDirectory: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fm.temporaryDirectory
            .appendingPathComponent("HardwareRequirementsMLXTests-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Valid directories

    func test_isValidMLXDirectory_withConfigAndSafetensors_returnsTrue() {
        createFile("config.json")
        createFile("model.safetensors")

        XCTAssertTrue(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_withMultipleSafetensors_returnsTrue() {
        createFile("config.json")
        createFile("model-00001-of-00002.safetensors")
        createFile("model-00002-of-00002.safetensors")

        XCTAssertTrue(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    // MARK: - Missing files

    func test_isValidMLXDirectory_missingConfig_returnsFalse() {
        createFile("model.safetensors")

        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_missingSafetensors_returnsFalse() {
        createFile("config.json")

        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    func test_isValidMLXDirectory_emptyDirectory_returnsFalse() {
        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(tempDirectory))
    }

    // MARK: - Not a directory

    func test_isValidMLXDirectory_fileInsteadOfDirectory_returnsFalse() {
        let fileURL = tempDirectory.appendingPathComponent("not-a-directory")
        fm.createFile(atPath: fileURL.path, contents: Data("hello".utf8))

        XCTAssertFalse(HardwareRequirements.isValidMLXDirectory(fileURL))
    }

    // MARK: - Helpers

    @discardableResult
    private func createFile(_ name: String) -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: Data())
        return url
    }
}

@preconcurrency import XCTest
@testable import BaseChatInference

/// Integration tests for `BackgroundDownloadManager.cleanupStaleTempFiles()`.
///
/// These exercise the launch-time sweep that reclaims `.download` temp files
/// orphaned by a prior process that crashed or was force-killed between
/// `URLSession`'s handoff and the move into the models directory.
///
/// The sweep scans the process temp directory — which is shared with every
/// other test — so tests must (a) only create files with a test-specific UUID
/// suffix and (b) remove everything they create in `tearDown` to avoid bleed.
@MainActor
final class DownloadTempCleanupTests: XCTestCase {

    /// Files we created during a test run — removed in tearDown regardless of outcome.
    private var createdURLs: [URL] = []

    override func tearDown() async throws {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a file in the process temp directory with the manager's naming
    /// signature and backdates its modification time.
    ///
    /// - Parameter age: Seconds in the past to stamp on the file's mtime.
    /// - Returns: The URL of the created file.
    @discardableResult
    private func makeTempDownloadFile(
        age: TimeInterval,
        contents: Data = Data("temp".utf8)
    ) throws -> URL {
        let name = "\(BackgroundDownloadManager.tempFilePrefix)\(UUID().uuidString).\(BackgroundDownloadManager.tempFileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        let backdatedDate = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes(
            [.modificationDate: backdatedDate],
            ofItemAtPath: url.path
        )
        createdURLs.append(url)
        return url
    }

    /// Creates a file in the temp directory that does NOT match the manager's
    /// naming signature, to verify the sweep leaves unrelated files alone.
    @discardableResult
    private func makeUnrelatedTempFile(age: TimeInterval) throws -> URL {
        let name = "unrelated-\(UUID().uuidString).tmp"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data("unrelated".utf8).write(to: url)
        let backdatedDate = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes(
            [.modificationDate: backdatedDate],
            ofItemAtPath: url.path
        )
        createdURLs.append(url)
        return url
    }

    // MARK: - Launch Sweep

    func test_cleanup_removesFileOlderThanThreshold() throws {
        // 48h old — well past the 24h threshold.
        let staleURL = try makeTempDownloadFile(age: 48 * 60 * 60)

        BackgroundDownloadManager.cleanupStaleTempFiles()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleURL.path),
            "Stale temp file older than the threshold should have been removed"
        )
    }

    func test_cleanup_preservesFileYoungerThanThreshold() throws {
        // 1h old — well inside the 24h threshold.
        let freshURL = try makeTempDownloadFile(age: 60 * 60)

        BackgroundDownloadManager.cleanupStaleTempFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: freshURL.path),
            "Fresh temp file must not be touched — it may belong to an in-flight download"
        )
    }

    func test_cleanup_leavesUnrelatedFilesUntouched() throws {
        // An unrelated stale file with the same age as the sweep target,
        // to prove the prefix/extension filter is doing the work.
        let unrelatedURL = try makeUnrelatedTempFile(age: 48 * 60 * 60)
        let managedURL = try makeTempDownloadFile(age: 48 * 60 * 60)

        BackgroundDownloadManager.cleanupStaleTempFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedURL.path),
            "Files that do not carry the manager's prefix/extension signature must be preserved"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: managedURL.path),
            "Managed stale file should have been removed"
        )
    }

    func test_cleanup_usesInjectedNowForAgeThreshold() throws {
        // File is 12h old, which would normally be preserved. But by passing
        // `now` far in the future we force it to cross the 24h threshold.
        let borderlineURL = try makeTempDownloadFile(age: 12 * 60 * 60)
        let forcedFuture = Date().addingTimeInterval(48 * 60 * 60)

        BackgroundDownloadManager.cleanupStaleTempFiles(now: forcedFuture)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: borderlineURL.path),
            "Sweep should treat the injected now as the reference time for the age comparison"
        )
    }

    func test_cleanup_isIdempotent() throws {
        // Second run with no matching files should be a silent no-op.
        let freshURL = try makeTempDownloadFile(age: 60 * 60)

        BackgroundDownloadManager.cleanupStaleTempFiles()
        BackgroundDownloadManager.cleanupStaleTempFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: freshURL.path),
            "Repeated cleanup calls must not alter state for fresh files"
        )
    }

    // MARK: - Constants Contract

    func test_tempFilePrefix_matchesDelegateOutput() {
        // Sanity: the prefix constant the sweep scans for is the same one the
        // delegate writes. If these drift, the sweep silently stops reclaiming
        // files — a regression that would otherwise go unnoticed.
        XCTAssertEqual(BackgroundDownloadManager.tempFilePrefix, "basechatkit-dl-")
        XCTAssertEqual(BackgroundDownloadManager.tempFileExtension, "download")
    }
}

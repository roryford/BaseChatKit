import XCTest
import SwiftData
@testable import BaseChatCore
import BaseChatInference
import BaseChatTestSupport

/// Tests for ``ConversationExporter`` — file output, filename sanitization,
/// and the SwiftData-fetching convenience overload.
///
/// Classified integration where we drive the persistence harness, unit
/// elsewhere.
@MainActor
final class ConversationExporterTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        stack = nil
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Pure path

    func test_export_writesFileWithExpectedExtension() throws {
        let session = ChatSessionRecord(title: "Hello")
        let file = try ConversationExporter.export(
            session: session,
            messages: [ChatMessageRecord(role: .user, content: "hi", sessionID: session.id)],
            format: MarkdownExportFormat(),
            directory: tempDir
        )

        XCTAssertTrue(file.suggestedFilename.hasSuffix(".md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func test_export_fileContentsMatchFormatOutput() throws {
        let format = MarkdownExportFormat()
        let session = ChatSessionRecord(title: "RoundTrip")
        let messages = [
            ChatMessageRecord(role: .user, content: "Q?", sessionID: session.id),
            ChatMessageRecord(role: .assistant, content: "A!", sessionID: session.id)
        ]

        let file = try ConversationExporter.export(
            session: session,
            messages: messages,
            format: format,
            directory: tempDir
        )

        let onDisk = try Data(contentsOf: file.url)
        let direct = try format.export(session: session, messages: messages)
        XCTAssertEqual(onDisk, direct)
    }

    func test_export_returnsContentTypeFromFormat() throws {
        let session = ChatSessionRecord(title: "ct")
        let file = try ConversationExporter.export(
            session: session,
            messages: [],
            format: JSONLExportFormat(),
            directory: tempDir
        )
        XCTAssertEqual(file.contentType.identifier, "public.json")
    }

    // MARK: - Filename sanitization

    func test_sanitiseStem_replacesPathSeparators() {
        XCTAssertFalse(ConversationExporter.sanitiseStem("a/b\\c").contains("/"))
        XCTAssertFalse(ConversationExporter.sanitiseStem("a/b\\c").contains("\\"))
    }

    func test_sanitiseStem_replacesControlCharacters() {
        XCTAssertFalse(ConversationExporter.sanitiseStem("hello\nworld").contains("\n"))
        XCTAssertFalse(ConversationExporter.sanitiseStem("hello\u{0007}bell").contains("\u{0007}"))
    }

    func test_sanitiseStem_fallsBackToChatWhenEmpty() {
        XCTAssertEqual(ConversationExporter.sanitiseStem(""), "chat")
        XCTAssertEqual(ConversationExporter.sanitiseStem("   \n\t  "), "chat")
    }

    func test_sanitiseStem_capsLength() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(ConversationExporter.sanitiseStem(long).count, 80)
    }

    func test_sanitisedFilename_appendsExtension() {
        let session = ChatSessionRecord(title: "demo")
        let name = ConversationExporter.sanitisedFilename(for: session, fileExtension: "jsonl")
        XCTAssertEqual(name, "demo.jsonl")
    }

    // MARK: - SwiftData convenience overload

    func test_export_viaPersistenceProvider_fetchesMessagesInOrder() throws {
        let session = ChatSession(title: "Provider Path")
        stack.context.insert(session)
        try stack.context.save()

        // Insert messages out of order to verify the exporter relies on
        // the provider's chronological sort, not raw fetch order.
        let later = ChatMessageRecord(
            role: .assistant,
            content: "second",
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            sessionID: session.id
        )
        let earlier = ChatMessageRecord(
            role: .user,
            content: "first",
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            sessionID: session.id
        )
        try stack.provider.insertMessage(later)
        try stack.provider.insertMessage(earlier)

        let file = try ConversationExporter.export(
            session: session,
            format: MarkdownExportFormat(),
            provider: stack.provider,
            directory: tempDir
        )

        let text = try String(contentsOf: file.url, encoding: .utf8)
        let firstRange = try XCTUnwrap(text.range(of: "first"))
        let secondRange = try XCTUnwrap(text.range(of: "second"))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
    }

    func test_export_useDefaultDirectory_writesToTemp() throws {
        // Exercise the nil-directory path so the temp-dir branch is covered.
        let session = ChatSessionRecord(title: "tempy")
        let file = try ConversationExporter.export(
            session: session,
            messages: [ChatMessageRecord(role: .user, content: "hi", sessionID: session.id)],
            format: MarkdownExportFormat(),
            directory: nil
        )

        XCTAssertTrue(
            file.url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
                || file.url.path.hasPrefix("/private\(FileManager.default.temporaryDirectory.path)"),
            "Expected default export to live under temp dir; got \(file.url.path)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))

        // Caller owns cleanup; clean up so we don't leak fixtures.
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }
}

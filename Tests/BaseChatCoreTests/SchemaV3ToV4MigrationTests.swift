import XCTest
import SwiftData
@testable import BaseChatCore
import BaseChatInference

/// Integration tests for the V3 → V4 SwiftData migration. These tests hit a
/// real (in-memory) SwiftData store and exercise the ``VersionedSchema`` +
/// ``SchemaMigrationPlan`` machinery end-to-end. Classified as integration,
/// not unit, per the testing conventions in CLAUDE.md.
///
/// Per-test UUID-named in-memory stores isolate state (see
/// `feedback_mockurlprotocol.md` — never call a global reset across suites).
final class SchemaV3ToV4MigrationTests: XCTestCase {

    // MARK: - Helpers

    /// Returns a unique on-disk path for a test store. Using disk (not the
    /// `/dev/null` in-memory sentinel) is required when we want to close a
    /// container and reopen the *same* store under a different schema.
    private func makeUniqueStoreURL() -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return tmp.appendingPathComponent("bck-v3tov4-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        let fm = FileManager.default
        // Clean the primary store and its SQLite sidecars.
        for suffix in ["", "-shm", "-wal"] {
            let path = url.path + suffix
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - 1. V3 row identity preserved after V3 → V4 migration

    func test_v3Rows_preservedIdentityAfterMigration() throws {
        let storeURL = makeUniqueStoreURL()
        defer { removeStore(at: storeURL) }

        // --- Seed the store under V3 only. ---
        let sessionID = UUID()
        let seededParts: [[MessagePart]] = [
            [.text("row 0 — plain text")],
            [.text("row 1 "), .text("two text parts")],
            [.thinking("row 2 reasoning"), .text("row 2 answer")],
            [.image(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg"), .text("row 3 caption")],
            [.text("row 4 first"), .image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")],
            [.thinking("row 5 — thinking only")],
            [.text("row 6"), .thinking("row 6 mid-thought"), .text("row 6 more")],
            [.text("row 7 — unicode 🧠🔥")],
            [.text(#"row 8 — embedded "quotes" and \backslashes"#)],
            [.text("row 9 final")],
        ]

        do {
            let config = ModelConfiguration(url: storeURL)
            let v3Container = try ModelContainer(
                for: Schema(versionedSchema: BaseChatSchemaV3.self),
                configurations: [config]
            )
            let ctx = ModelContext(v3Container)
            for parts in seededParts {
                let msg = BaseChatSchemaV3.ChatMessage(
                    role: .assistant,
                    contentParts: parts,
                    sessionID: sessionID
                )
                ctx.insert(msg)
            }
            try ctx.save()
        }

        // --- Reopen with V4 + migration plan. ---
        let config = ModelConfiguration(url: storeURL)
        let v4Container = try ModelContainer(
            for: Schema(versionedSchema: BaseChatSchemaV4.self),
            migrationPlan: BaseChatMigrationPlan.self,
            configurations: [config]
        )
        let ctx = ModelContext(v4Container)
        let descriptor = FetchDescriptor<BaseChatSchemaV4.ChatMessage>()
        let fetched = try ctx.fetch(descriptor)

        XCTAssertEqual(fetched.count, seededParts.count,
            "Every V3 row must survive migration")

        // SABOTAGE HOOK (kept off in normal runs). Flip this to `true` to
        // corrupt one migrated row's payload and confirm the identity
        // assertion below catches the drift. Verified by this suite's author
        // before commit; left in place as documentation of the check.
        let SABOTAGE_CORRUPT_ONE_ROW = false
        if SABOTAGE_CORRUPT_ONE_ROW, let victim = fetched.first {
            victim.contentPartsJSON = #"[{"text":{"_0":"corrupted"}}]"#
            try ctx.save()
        }

        // Build a lookup by the stored .content so ordering across SwiftData
        // fetches is irrelevant.
        let byText: [String: BaseChatSchemaV4.ChatMessage] = Dictionary(
            fetched.map { ($0.content, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        for parts in seededParts {
            let expectedText = parts.compactMap(\.textContent).joined()
            guard let row = byText[expectedText] else {
                XCTFail("Missing migrated row for text '\(expectedText)'")
                continue
            }
            XCTAssertEqual(row.contentParts, parts,
                "Row with .content='\(expectedText)' must decode to the same [MessagePart] after migration")
        }
    }

    // MARK: - 2. Mixed-store writes after migration

    func test_v4Store_newToolParts_persistAndDecode() throws {
        let storeURL = makeUniqueStoreURL()
        defer { removeStore(at: storeURL) }

        let sessionID = UUID()

        // Seed V3 with a plain text row.
        do {
            let config = ModelConfiguration(url: storeURL)
            let v3Container = try ModelContainer(
                for: Schema(versionedSchema: BaseChatSchemaV3.self),
                configurations: [config]
            )
            let ctx = ModelContext(v3Container)
            ctx.insert(BaseChatSchemaV3.ChatMessage(
                role: .user,
                content: "what's the weather?",
                sessionID: sessionID
            ))
            try ctx.save()
        }

        // Open under V4, append a message carrying tool parts.
        let newToolCallID = "call_weather_1"
        do {
            let config = ModelConfiguration(url: storeURL)
            let v4Container = try ModelContainer(
                for: Schema(versionedSchema: BaseChatSchemaV4.self),
                migrationPlan: BaseChatMigrationPlan.self,
                configurations: [config]
            )
            let ctx = ModelContext(v4Container)
            let parts: [MessagePart] = [
                .thinking("I need to check the weather tool."),
                .toolCall(ToolCall(
                    id: newToolCallID,
                    toolName: "get_weather",
                    arguments: #"{"city":"Paris"}"#
                )),
                .toolResult(ToolResult(
                    callId: newToolCallID,
                    content: #"{"temp":18,"unit":"C"}"#,
                    isError: false
                )),
                .text("It's 18°C in Paris."),
            ]
            ctx.insert(BaseChatSchemaV4.ChatMessage(
                role: .assistant,
                contentParts: parts,
                sessionID: sessionID
            ))
            try ctx.save()
        }

        // Reopen fresh, confirm both the old and new rows decode cleanly.
        let config = ModelConfiguration(url: storeURL)
        let v4Container = try ModelContainer(
            for: Schema(versionedSchema: BaseChatSchemaV4.self),
            migrationPlan: BaseChatMigrationPlan.self,
            configurations: [config]
        )
        let ctx = ModelContext(v4Container)
        let rows = try ctx.fetch(FetchDescriptor<BaseChatSchemaV4.ChatMessage>())
        XCTAssertEqual(rows.count, 2, "V3 seed row + new V4 row")

        let assistantRow = rows.first { $0.role == .assistant }
        XCTAssertNotNil(assistantRow)
        let assistantParts = assistantRow?.contentParts ?? []
        XCTAssertEqual(assistantParts.count, 4)
        XCTAssertEqual(assistantParts.first?.thinkingContent, "I need to check the weather tool.")
        XCTAssertEqual(assistantParts[1].toolCallContent?.id, newToolCallID)
        XCTAssertEqual(assistantParts[1].toolCallContent?.toolName, "get_weather")
        XCTAssertEqual(assistantParts[2].toolResultContent?.callId, newToolCallID)
        XCTAssertEqual(assistantParts[2].toolResultContent?.isError, false)
        XCTAssertEqual(assistantParts.last?.textContent, "It's 18°C in Paris.")

        let userRow = rows.first { $0.role == .user }
        XCTAssertEqual(userRow?.contentParts, [.text("what's the weather?")],
            "V3-era row must still decode unchanged after sharing a store with new tool-part rows")
    }

    // MARK: - 3. V3 fallback safety net still works

    func test_v3Decoder_malformedJSON_fallsBackToText() {
        // Malformed discriminator — not an array, not a known enum key.
        let bogus = #"{"mystery":"not a valid part"}"#
        let parts = BaseChatSchemaV3.ChatMessage.decode(bogus)
        XCTAssertEqual(parts, [.text(bogus)],
            "V3 decoder must degrade gracefully to .text for genuinely malformed JSON — this safety net is load-bearing until V5")
    }

    // MARK: - 4. V4 → hypothetical-older-reader downgrade probe

    func test_v4ToolParts_readByLegacyStyleDecoder_fallsBackWithoutCrash() {
        // Simulates a hypothetical BCK binary from before this PR reading a
        // row that a newer binary wrote. We can't instantiate an actually
        // older ``MessagePart`` type inside the current process, so we fake
        // it by hand-crafting the JSON vocabulary that the pre-PR decoder
        // would have rejected (an unknown `"toolCall"` discriminator) and
        // running it through the V3 decode helper, which is the read path
        // such a binary would use.
        let legacyStyleBlob = #"""
        [{"text":{"_0":"hi"}},{"toolCall":{"_0":{"id":"c1","toolName":"echo","arguments":"{}"}}}]
        """#

        // A hand-crafted pre-PR reader would have thrown on `toolCall` and
        // hit the text fallback in ``BaseChatSchemaV3/ChatMessage/decode(_:)``.
        // In the current binary the same decode helper succeeds — either
        // outcome is acceptable; what we lock in is the no-crash contract.
        let parts = BaseChatSchemaV3.ChatMessage.decode(legacyStyleBlob)
        XCTAssertFalse(parts.isEmpty,
            "Downgrade-style read of V4 tool-part JSON must never produce an empty array (message would vanish from history)")
    }
}

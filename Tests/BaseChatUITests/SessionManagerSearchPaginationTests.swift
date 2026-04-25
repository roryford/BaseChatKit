@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Covers the search + pagination surface added in #246. Drives a real
/// in-memory SwiftData store via the production
/// ``SwiftDataPersistenceProvider`` so the VM logic and the underlying
/// SwiftData predicate stay in lock-step.
@MainActor
final class SessionManagerSearchPaginationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: SessionManagerViewModel!
    private var persistence: SwiftDataPersistenceProvider!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        persistence = SwiftDataPersistenceProvider(modelContext: context)
        vm = SessionManagerViewModel()
        vm.configure(persistence: persistence)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        persistence = nil
        vm = nil
        try await super.tearDown()
    }

    // MARK: - Title search

    func test_titleSearch_isCaseInsensitive() throws {
        try seedSessions(titles: ["Travel Plan", "Recipes", "TRAVEL guide", "Other"])
        vm.loadSessions()

        vm.runTitleSearch("travel")

        XCTAssertEqual(vm.titleMatches.count, 2)
        XCTAssertTrue(vm.titleMatches.contains { $0.title == "Travel Plan" })
        XCTAssertTrue(vm.titleMatches.contains { $0.title == "TRAVEL guide" })
    }

    func test_titleSearch_emptyQueryClearsMatches() throws {
        try seedSessions(titles: ["A", "B"])
        vm.loadSessions()
        vm.runTitleSearch("A")
        XCTAssertFalse(vm.titleMatches.isEmpty)

        vm.runTitleSearch("")

        XCTAssertTrue(vm.titleMatches.isEmpty)
    }

    func test_titleSearch_preservesRecencyOrder() throws {
        try seedSessions(titles: ["alpha old", "alpha new", "beta"], spacingSeconds: 60)
        vm.loadSessions()

        vm.runTitleSearch("alpha")

        // loadSessions returns newest-first; the filter must preserve that order.
        XCTAssertEqual(vm.titleMatches.map(\.title), ["alpha new", "alpha old"])
    }

    // MARK: - Message search

    func test_messageSearch_returnsSessionsWithMatchingMessages() throws {
        let s1 = try seedSession(title: "S1")
        let s2 = try seedSession(title: "S2")
        let s3 = try seedSession(title: "S3")
        try persistence.insertMessage(ChatMessageRecord(role: .user, content: "tell me about NEEDLE in haystack", sessionID: s1.id))
        try persistence.insertMessage(ChatMessageRecord(role: .user, content: "no match here", sessionID: s2.id))
        try persistence.insertMessage(ChatMessageRecord(role: .user, content: "more needle talk", sessionID: s3.id))
        vm.loadSessions()

        vm.runMessageSearch("needle")

        XCTAssertEqual(Set(vm.messageMatchSessions.map(\.id)), [s1.id, s3.id])
        XCTAssertEqual(vm.messageHitsBySession[s1.id]?.count, 1)
        XCTAssertEqual(vm.messageHitsBySession[s3.id]?.count, 1)
        XCTAssertNil(vm.messageHitsBySession[s2.id])
    }

    func test_messageSearch_emptyQueryClearsResults() throws {
        let s1 = try seedSession(title: "S1")
        try persistence.insertMessage(ChatMessageRecord(role: .user, content: "needle", sessionID: s1.id))
        vm.runMessageSearch("needle")
        XCTAssertFalse(vm.messageMatchSessions.isEmpty)

        vm.runMessageSearch("")

        XCTAssertTrue(vm.messageMatchSessions.isEmpty)
        XCTAssertTrue(vm.messageHitsBySession.isEmpty)
    }

    func test_messageSearch_snippetIsHighlightable() throws {
        let s = try seedSession(title: "S")
        try persistence.insertMessage(ChatMessageRecord(role: .user, content: "find the NEEDLE here", sessionID: s.id))

        vm.runMessageSearch("needle")

        let hit = try XCTUnwrap(vm.messageHitsBySession[s.id]?.first)
        XCTAssertTrue(String(hit.snippet[hit.matchRange]).localizedStandardContains("needle"))
    }

    // MARK: - Display + empty state

    func test_displayedSessions_fallsBackToFullListWhenQueryEmpty() throws {
        try seedSessions(titles: ["a", "b", "c"])
        vm.loadSessions()

        XCTAssertEqual(vm.displayedSessions.count, 3)
        XCTAssertFalse(vm.hasNoSearchResults)
    }

    func test_hasNoSearchResults_trueWhenTitleQueryMatchesNothing() throws {
        try seedSessions(titles: ["alpha", "beta"])
        vm.loadSessions()

        vm.searchScope = .titles
        vm.searchQuery = "absent"
        vm.runTitleSearch("absent")

        XCTAssertTrue(vm.hasNoSearchResults)
        XCTAssertTrue(vm.displayedSessions.isEmpty)
    }

    func test_clearSearch_resetsToFullList() throws {
        try seedSessions(titles: ["one", "two"])
        vm.loadSessions()
        vm.searchQuery = "one"
        vm.runTitleSearch("one")
        XCTAssertEqual(vm.titleMatches.count, 1)

        vm.clearSearch()

        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertEqual(vm.displayedSessions.count, 2)
        XCTAssertFalse(vm.hasNoSearchResults)
    }

    // MARK: - Pagination

    func test_loadSessions_loadsFirstPageOnly() throws {
        try seedSessions(count: 120, prefix: "S", spacingSeconds: 1)

        vm.loadSessions()

        XCTAssertEqual(vm.sessions.count, SessionManagerViewModel.sessionsPageSize)
        XCTAssertTrue(vm.hasMoreSessions, "Should signal more pages remain")
    }

    func test_loadNextPage_appendsAndAdvancesCursor() throws {
        try seedSessions(count: 130, prefix: "S", spacingSeconds: 1)
        vm.loadSessions()
        XCTAssertEqual(vm.sessions.count, 50)

        vm.loadNextPage()
        XCTAssertEqual(vm.sessions.count, 100)
        XCTAssertTrue(vm.hasMoreSessions)

        vm.loadNextPage()
        XCTAssertEqual(vm.sessions.count, 130)
        XCTAssertFalse(vm.hasMoreSessions, "Final partial page must clear hasMoreSessions")
    }

    func test_loadNextPage_isNoOpAtEnd() throws {
        try seedSessions(count: 20, prefix: "S", spacingSeconds: 1)
        vm.loadSessions()
        XCTAssertEqual(vm.sessions.count, 20)
        XCTAssertFalse(vm.hasMoreSessions)

        vm.loadNextPage()
        XCTAssertEqual(vm.sessions.count, 20)
    }

    func test_fetchSessionsPage_returnsRequestedSliceWithoutMutatingVM() throws {
        try seedSessions(count: 60, prefix: "S", spacingSeconds: 1)
        vm.loadSessions()
        let snapshotCount = vm.sessions.count

        let page = try vm.fetchSessionsPage(offset: 50, limit: 50)

        XCTAssertEqual(page.count, 10)
        XCTAssertEqual(vm.sessions.count, snapshotCount, "Fetch helper must not mutate VM state")
    }

    // MARK: - Helpers

    private func seedSession(title: String, updatedAt: Date = Date()) throws -> ChatSessionRecord {
        let record = ChatSessionRecord(title: title, updatedAt: updatedAt)
        try persistence.insertSession(record)
        return record
    }

    private func seedSessions(titles: [String], spacingSeconds: TimeInterval = 1) throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        for (i, title) in titles.enumerated() {
            try persistence.insertSession(ChatSessionRecord(
                title: title,
                updatedAt: base.addingTimeInterval(Double(i) * spacingSeconds)
            ))
        }
    }

    private func seedSessions(count: Int, prefix: String, spacingSeconds: TimeInterval) throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<count {
            try persistence.insertSession(ChatSessionRecord(
                title: "\(prefix)\(i)",
                updatedAt: base.addingTimeInterval(Double(i) * spacingSeconds)
            ))
        }
    }
}

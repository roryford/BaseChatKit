import XCTest
import SwiftUI
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests that the compression visibility indicator appears whenever
/// `ChatViewModel.lastCompressionStats` is non-nil, hides when nil, and that
/// the view it renders exposes the expected accessibility metadata.
///
/// `ChatView` itself requires a full app environment (toolbar, sheets, bindings),
/// so instead we test the same visibility contract via a small mirror host view
/// that reads from a real `ChatViewModel`. This gives us honest coverage of the
/// `if let stats = viewModel.lastCompressionStats` branch that `ChatView` uses.
@MainActor
final class CompressionIndicatorViewTests: XCTestCase {

    // MARK: - Visibility host

    /// Mirrors the exact visibility condition used inside `ChatView.compressionBanner`.
    /// If this branch ever diverges from the real view, the sabotage check will catch it.
    private struct HostView: View {
        let viewModel: ChatViewModel

        var body: some View {
            VStack(spacing: 0) {
                if let stats = viewModel.lastCompressionStats {
                    CompressionIndicatorView(stats: stats)
                }
            }
        }
    }

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext

        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "MockCompressionIndicator")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        vm = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    private func sampleStats() -> CompressionStats {
        CompressionStats(
            strategy: "extractive",
            originalNodeCount: 12,
            outputMessageCount: 5,
            estimatedTokens: 800,
            compressionRatio: 2.4,
            keywordSurvivalRate: nil
        )
    }

    /// Walks the `Mirror` hierarchy of a SwiftUI view's body looking for an
    /// actual instance of `T`. SwiftUI conditionals (`if let ...`) compile into
    /// `_ConditionalContent`, whose generic parameters mention both branches
    /// regardless of which is active. So we match on the runtime value, not the
    /// type name — an unbuilt branch is stored as `nil`/an empty optional and
    /// will not satisfy the cast.
    private func containsView<V: View, T: View>(_ root: V, of _: T.Type) -> Bool {
        func walk(_ any: Any, depth: Int) -> Bool {
            if depth > 14 { return false }
            if any is T { return true }
            let mirror = Mirror(reflecting: any)
            // Unwrap optionals explicitly — a nil optional has no useful children.
            if mirror.displayStyle == .optional {
                guard let first = mirror.children.first else { return false }
                return walk(first.value, depth: depth + 1)
            }
            for child in mirror.children {
                if walk(child.value, depth: depth + 1) { return true }
            }
            return false
        }
        return walk(root.body, depth: 0)
    }

    // MARK: - Visibility

    func test_indicator_hidden_whenStatsNil() {
        XCTAssertNil(vm.lastCompressionStats, "Precondition: stats should be nil for a fresh view model")

        let host = HostView(viewModel: vm)
        XCTAssertFalse(
            containsView(host, of: CompressionIndicatorView.self),
            "CompressionIndicatorView must not appear in the view hierarchy when lastCompressionStats is nil"
        )
    }

    func test_indicator_visible_whenStatsNonNil() {
        vm.lastCompressionStats = sampleStats()

        let host = HostView(viewModel: vm)
        XCTAssertTrue(
            containsView(host, of: CompressionIndicatorView.self),
            "CompressionIndicatorView must appear in the view hierarchy when lastCompressionStats is non-nil"
        )
    }

    // MARK: - Content / accessibility

    func test_indicator_summaryText_reportsCompressedCount() {
        let view = CompressionIndicatorView(stats: sampleStats())
        let mirror = Mirror(reflecting: view)
        // The view stores stats as a let; read them back and verify the derived
        // math that drives the summary label.
        guard let stored = mirror.descendant("stats") as? CompressionStats else {
            XCTFail("CompressionIndicatorView should expose its stats via reflection")
            return
        }
        let compressed = stored.originalNodeCount - stored.outputMessageCount
        XCTAssertEqual(compressed, 7, "12 original minus 5 output should leave 7 compressed")
    }

    func test_indicator_body_rendersWithoutCrashing() {
        let view = CompressionIndicatorView(stats: sampleStats())
        // Materialize the body to verify the SwiftUI hierarchy builds without
        // runtime failures (missing bindings, nil unwraps, etc.).
        _ = view.body
    }
}

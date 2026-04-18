import XCTest
import Foundation
@testable import BaseChatInference
import BaseChatTestSupport

/// Direct unit tests for the `GenerationCoordinator`.
///
/// The coordinator is `internal`, so this file uses `@testable import
/// BaseChatInference` to construct it directly. Injecting a
/// `FakeGenerationContextProvider` replaces the `InferenceService`-shaped
/// dependency without standing up an entire service. Thermal-gate tests
/// inject a deterministic `thermalStateProvider` closure.
@MainActor
final class GenerationCoordinatorTests: XCTestCase {

    // MARK: - Fixture

    private var provider: FakeGenerationContextProvider!
    private var coordinator: GenerationCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
        coordinator = GenerationCoordinator()
        coordinator.provider = provider
    }

    override func tearDown() async throws {
        coordinator?.stopGeneration()
        coordinator = nil
        provider = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Makes a coordinator with the given thermal closure.
    private func makeCoordinator(
        thermal: @escaping @Sendable () -> ProcessInfo.ThermalState
    ) -> GenerationCoordinator {
        let coord = GenerationCoordinator(thermalStateProvider: thermal)
        coord.provider = provider
        return coord
    }

    // MARK: - Queue overflow

    func test_enqueue_overQueueDepth_throwsQueueFullError() throws {
        // Saturate the coordinator: one active plus eight queued is the hard cap
        // (maxQueueDepth == 8 counts queued requests only).
        for i in 0..<9 {
            _ = try coordinator.enqueue(messages: [("user", "msg \(i)")], priority: .normal)
        }

        // The 10th enqueue must throw the "queue is full" variant of
        // InferenceError.inferenceFailure — pin the message so a future
        // dedicated error case doesn't regress the text silently.
        XCTAssertThrowsError(
            try coordinator.enqueue(messages: [("user", "overflow")], priority: .normal)
        ) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                return XCTFail("expected InferenceError.inferenceFailure, got \(error)")
            }
            XCTAssertEqual(message, "Generation queue is full")
        }
    }

    // MARK: - Priority insertion

    func test_enqueue_userInitiatedBehindBackground_drainsFirst() async throws {
        // Freeze the active slot with a slow backend so queued requests can
        // accumulate without racing their own drain.
        let slow = SlowMockBackend(tokenCount: 10, delayMilliseconds: 30)
        let slowProvider = FakeGenerationContextProviderWithSlowBackend(backend: slow)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        // Put one request on the active slot (normal priority).
        let (_, activeStream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)

        // Queue two .background and then one .userInitiated.
        let (bgToken1, _) = try coord.enqueue(messages: [("user", "bg1")], priority: .background)
        let (bgToken2, _) = try coord.enqueue(messages: [("user", "bg2")], priority: .background)
        let (uiToken, _) = try coord.enqueue(messages: [("user", "ui")], priority: .userInitiated)

        // Read the queue directly via the @testable seam to verify ordering.
        // The queue should be [userInitiated, background1, background2].
        let order = coord.queuedRequestTokensForTesting()
        XCTAssertEqual(
            order,
            [uiToken, bgToken1, bgToken2],
            "userInitiated must sort ahead of earlier-enqueued background requests"
        )

        // Drain the active so the queue actually advances, then stop.
        _ = activeStream
        coord.stopGeneration()
    }

    // MARK: - Cancel: queued

    func test_cancel_queuedRequest_removesFromQueueAndLeavesActiveRunning() async throws {
        let slow = SlowMockBackend(tokenCount: 20, delayMilliseconds: 20)
        let slowProvider = FakeGenerationContextProviderWithSlowBackend(backend: slow)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (_, activeStream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)
        let (queuedToken, queuedStream) = try coord.enqueue(
            messages: [("user", "queued")], priority: .normal
        )

        // Cancel the queued one — not the active one.
        coord.cancel(queuedToken)

        // The queued stream must complete (with a CancellationError finish).
        // Consume it; confirm no tokens arrive.
        var tokens: [String] = []
        do {
            for try await event in queuedStream.events {
                if case .token(let t) = event { tokens.append(t) }
            }
        } catch {
            // CancellationError is acceptable — the coordinator finishes the
            // continuation with an error when cancelling a queued item.
        }
        XCTAssertTrue(tokens.isEmpty, "cancelled queued request must not emit tokens")

        // The active stream should still be running; stopGeneration cleans up.
        _ = activeStream
        coord.stopGeneration()
    }

    // MARK: - Cancel: active (no-token-after-cancel)

    /// Key invariant: after `cancel` returns for the active request, **no
    /// `.token` events may be delivered on that request's continuation**. Even
    /// if the backend is still running, the coordinator must have torn down
    /// the continuation such that further yields are dropped.
    func test_cancel_activeRequest_noTokenAfterCancel() async throws {
        let slow = SlowMockBackend(tokenCount: 50, delayMilliseconds: 20)
        let slowProvider = FakeGenerationContextProviderWithSlowBackend(backend: slow)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (token, stream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)

        // Start consuming the stream and collect tokens until we see the first
        // one — then cancel.
        var tokensBeforeCancel = 0
        var tokensAfterCancel = 0
        var didCancel = false

        do {
            for try await event in stream.events {
                if case .token = event {
                    if !didCancel {
                        tokensBeforeCancel += 1
                        if tokensBeforeCancel >= 1 {
                            coord.cancel(token)
                            didCancel = true
                        }
                    } else {
                        tokensAfterCancel += 1
                    }
                }
            }
        } catch {
            // CancellationError (or the "Cancelled" wrap) is expected.
        }

        XCTAssertGreaterThanOrEqual(
            tokensBeforeCancel, 1,
            "precondition: at least one token should arrive before the cancel"
        )
        XCTAssertEqual(
            tokensAfterCancel, 0,
            "no tokens may be delivered on the continuation after cancel() returns"
        )
    }

    // MARK: - stopGeneration: continuations.count == 0

    func test_stopGeneration_emptiesQueueAndContinuations() async throws {
        let slow = SlowMockBackend(tokenCount: 50, delayMilliseconds: 20)
        let slowProvider = FakeGenerationContextProviderWithSlowBackend(backend: slow)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        _ = try coord.enqueue(messages: [("user", "active")], priority: .normal)
        _ = try coord.enqueue(messages: [("user", "queued1")], priority: .normal)
        _ = try coord.enqueue(messages: [("user", "queued2")], priority: .normal)

        coord.stopGeneration()

        XCTAssertFalse(coord.isGenerating)
        XCTAssertFalse(coord.hasQueuedRequests)
        XCTAssertEqual(
            coord.continuationsCountForTesting(), 0,
            "stopGeneration must drain continuations to zero"
        )
    }

    // MARK: - discardRequests(notMatching:)

    func test_discardRequests_keepsMatchingSessionCancelsOthers() async throws {
        let slow = SlowMockBackend(tokenCount: 50, delayMilliseconds: 20)
        let slowProvider = FakeGenerationContextProviderWithSlowBackend(backend: slow)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let keepSession = UUID()
        let dropSession = UUID()

        // Active request belongs to keepSession.
        let (_, activeStream) = try coord.enqueue(
            messages: [("user", "active")], priority: .normal, sessionID: keepSession
        )
        // Queued: two matching, one not.
        let (keepToken, keepStream) = try coord.enqueue(
            messages: [("user", "keep")], priority: .normal, sessionID: keepSession
        )
        let (dropToken, dropStream) = try coord.enqueue(
            messages: [("user", "drop")], priority: .normal, sessionID: dropSession
        )

        coord.discardRequests(notMatching: keepSession)

        // keepToken should still be queued; dropToken must be gone.
        let queued = coord.queuedRequestTokensForTesting()
        XCTAssertTrue(queued.contains(keepToken), "matching session must be preserved")
        XCTAssertFalse(queued.contains(dropToken), "non-matching session must be cancelled")

        // Drop stream should terminate (with an error).
        var dropTokens: [String] = []
        do {
            for try await event in dropStream.events {
                if case .token(let t) = event { dropTokens.append(t) }
            }
        } catch {
            // expected
        }
        XCTAssertTrue(dropTokens.isEmpty)

        _ = activeStream
        _ = keepStream
        coord.stopGeneration()
    }

    // MARK: - isGenerating transitions

    func test_isGenerating_transitions_onNormalCompletion() async throws {
        XCTAssertFalse(coordinator.isGenerating)

        provider.backend.tokensToYield = ["a", "b"]
        let (_, stream) = try coordinator.enqueue(messages: [("user", "hi")], priority: .normal)

        // After enqueue returns, drainQueue has flipped isGenerating to true.
        XCTAssertTrue(coordinator.isGenerating, "isGenerating must flip true immediately on drain")

        // Consume the stream so the defer block runs and resets state.
        for try await _ in stream.events {}
        // Give the defer block a turn.
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(coordinator.isGenerating, "isGenerating must reset to false on completion")
    }

    func test_isGenerating_transitions_onError() async throws {
        struct Boom: Error {}
        provider.backend.shouldThrowInsideStream = Boom()
        provider.backend.tokensToYield = ["x"]

        let (_, stream) = try coordinator.enqueue(messages: [("user", "hi")], priority: .normal)
        XCTAssertTrue(coordinator.isGenerating)

        do {
            for try await _ in stream.events {}
        } catch {
            // expected
        }
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(coordinator.isGenerating, "isGenerating must reset to false on error")
    }

    func test_isGenerating_transitions_onCancel() async throws {
        let slow = SlowMockBackend(tokenCount: 50, delayMilliseconds: 20)
        let slowProvider = FakeGenerationContextProviderWithSlowBackend(backend: slow)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (token, stream) = try coord.enqueue(messages: [("user", "hi")], priority: .normal)
        XCTAssertTrue(coord.isGenerating)

        // Consume one token so we know generation is truly in flight.
        var iter = stream.events.makeAsyncIterator()
        _ = try await iter.next()

        coord.cancel(token)
        XCTAssertFalse(coord.isGenerating, "cancel() must flip isGenerating to false synchronously")
    }

    // MARK: - drainQueue re-entry race

    /// `cancel` may fire between `finishAndDiscard` and the synchronous
    /// `drainQueue()` call inside `cancel()`. The coordinator must survive
    /// this without crashing or leaking continuations.
    func test_drainQueue_reentryRace_noCrash_stateConsistent() async throws {
        let slow = SlowMockBackend(tokenCount: 2, delayMilliseconds: 5)
        let slowProvider = FakeGenerationContextProviderWithSlowBackend(backend: slow)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (token1, s1) = try coord.enqueue(messages: [("user", "a")], priority: .normal)
        let (token2, s2) = try coord.enqueue(messages: [("user", "b")], priority: .normal)

        // Cancel the active immediately, interleaved with a yield so the
        // defer block gets a chance to fire concurrently with the cancel path.
        coord.cancel(token1)
        await Task.yield()
        coord.cancel(token2)
        await Task.yield()

        // Consume both streams to completion so no task is leaked.
        // Cancelled streams finish with a thrown CancellationError, which is
        // expected here — swallow it so the race assertions run.
        do { for try await _ in s1.events {} } catch { /* expected cancel */ }
        do { for try await _ in s2.events {} } catch { /* expected cancel */ }

        XCTAssertFalse(coord.isGenerating)
        XCTAssertFalse(coord.hasQueuedRequests)
        XCTAssertEqual(coord.continuationsCountForTesting(), 0)
    }

    // MARK: - Enqueue ambiguous guard pinning

    /// The guard at line 121 combines `provider?.currentBackend != nil` and
    /// `provider?.isBackendLoaded == true`. If either fails, the same
    /// "No model loaded" error fires. Pin this so a future guard split
    /// can't silently change the observable error.
    func test_enqueue_noBackend_throwsNoModelLoaded() {
        // Tear off the backend: currentBackend becomes nil.
        // We can model this by allocating a fresh fake with an unloaded backend
        // and then nil-ing via a subclass that returns nil for currentBackend.
        let nilProvider = NilBackendProvider()
        let coord = GenerationCoordinator()
        coord.provider = nilProvider

        XCTAssertThrowsError(
            try coord.enqueue(messages: [("user", "x")], priority: .normal)
        ) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                return XCTFail("expected inferenceFailure, got \(error)")
            }
            XCTAssertEqual(message, "No model loaded")
        }
    }

    func test_enqueue_backendPresentButUnloaded_throwsNoModelLoaded() {
        // Backend is non-nil, but isBackendLoaded is false.
        provider.backend.isModelLoaded = false

        XCTAssertThrowsError(
            try coordinator.enqueue(messages: [("user", "x")], priority: .normal)
        ) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                return XCTFail("expected inferenceFailure, got \(error)")
            }
            XCTAssertEqual(message, "No model loaded")
        }
    }

    // MARK: - Thermal drop / NOT-drop

    func test_backgroundPriority_seriousThermal_requestDropped() async throws {
        let coord = makeCoordinator { .serious }

        let (_, stream) = try coord.enqueue(
            messages: [("user", "bg")], priority: .background
        )

        // The request must be dropped without invoking the backend.
        // Stream should terminate with an error.
        var tokenCount = 0
        do {
            for try await event in stream.events {
                if case .token = event { tokenCount += 1 }
            }
        } catch {
            // expected: thermal-throttle inferenceFailure
        }

        XCTAssertEqual(
            provider.backend.generateCallCount, 0,
            "thermal-dropped background request must never call the backend"
        )
        XCTAssertEqual(tokenCount, 0)
        XCTAssertFalse(coord.isGenerating)
    }

    func test_normalPriority_seriousThermal_requestNotDropped() async throws {
        let coord = makeCoordinator { .serious }

        provider.backend.tokensToYield = ["ok"]
        let (_, stream) = try coord.enqueue(
            messages: [("user", "normal")], priority: .normal
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        XCTAssertEqual(tokens, ["ok"])
        XCTAssertEqual(
            provider.backend.generateCallCount, 1,
            "normal-priority requests are NOT thermal-dropped"
        )
    }

    // MARK: - Provider teardown safety

    /// Deallocating the provider mid-stream must not crash the coordinator.
    /// The `weak var provider` goes nil and in-flight generation ends cleanly.
    func test_providerTeardown_midStream_noCrash_cleanEnd() async throws {
        let slow = SlowMockBackend(tokenCount: 20, delayMilliseconds: 20)
        var slowProvider: FakeGenerationContextProviderWithSlowBackend? =
            FakeGenerationContextProviderWithSlowBackend(backend: slow)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (_, stream) = try coord.enqueue(messages: [("user", "x")], priority: .normal)

        // Consume a token, then release our strong ref so the weak var goes nil.
        var iter = stream.events.makeAsyncIterator()
        _ = try await iter.next()
        slowProvider = nil

        // Stop the backend's running task — this unblocks the for-await loop
        // inside the coordinator's active task without needing the provider.
        slow.stopGeneration()

        // Drain the rest of the stream.
        while let _ = try? await iter.next() {}

        // The coordinator must be in a stable state: no crash, no active
        // generation.
        XCTAssertFalse(coord.isGenerating)
        XCTAssertNil(coord.provider as? FakeGenerationContextProviderWithSlowBackend)
    }
}

// MARK: - Local test doubles

/// A second `GenerationContextProvider` fake that vends a `SlowMockBackend`.
/// Lives here (not TestSupport) because `FakeGenerationContextProvider` is
/// intentionally tied to `MockInferenceBackend` for the common case; tests
/// that need delayed token streams reach for this instead.
@MainActor
private final class FakeGenerationContextProviderWithSlowBackend: GenerationContextProvider {
    let backend: SlowMockBackend
    init(backend: SlowMockBackend) { self.backend = backend }
    var currentBackend: (any InferenceBackend)? { backend }
    var isBackendLoaded: Bool { backend.isModelLoaded }
    var selectedPromptTemplate: PromptTemplate { .chatML }
}

/// A provider where `currentBackend` returns nil — used to exercise the
/// `currentBackend == nil` branch of the enqueue guard.
@MainActor
private final class NilBackendProvider: GenerationContextProvider {
    var currentBackend: (any InferenceBackend)? { nil }
    var isBackendLoaded: Bool { false }
    var selectedPromptTemplate: PromptTemplate { .chatML }
}

// MARK: - Test-only coordinator inspection helpers

extension GenerationCoordinator {
    /// Exposes the internal queue ordering so priority-insertion tests can
    /// verify the queue layout without consuming streams.
    ///
    /// `@Observable` rewrites stored properties to `_`-prefixed names, so
    /// the mirror lookup matches both the raw and the observed-prefix name.
    func queuedRequestTokensForTesting() -> [GenerationRequestToken] {
        Mirror(reflecting: self).children.compactMap { child -> [GenerationRequestToken]? in
            guard child.label == "requestQueue" || child.label == "_requestQueue" else { return nil }
            guard let queue = child.value as? [Any] else { return nil }
            return queue.compactMap { element -> GenerationRequestToken? in
                Mirror(reflecting: element).children.first(where: { $0.label == "token" })?
                    .value as? GenerationRequestToken
            }
        }.first ?? []
    }

    /// Exposes the internal continuations-map size for the `stopGeneration`
    /// sabotage check. Mirrors over the `[GenerationRequestToken: Continuation]`
    /// dictionary's children count.
    func continuationsCountForTesting() -> Int {
        Mirror(reflecting: self).children.first(where: { child in
            child.label == "continuations" || child.label == "_continuations"
        }).flatMap { child -> Int? in
            Mirror(reflecting: child.value).children.count
        } ?? 0
    }
}

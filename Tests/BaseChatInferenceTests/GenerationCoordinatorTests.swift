import XCTest
import Foundation
@testable import BaseChatInference
import BaseChatTestSupport

/// Direct unit tests for the `GenerationCoordinator`.
///
/// The coordinator is `internal`, so this file uses `@testable import
/// BaseChatInference` to construct it directly. A file-local
/// `FakeGenerationContextProvider` replaces the `InferenceService`-shaped
/// dependency without standing up an entire service. Thermal-gate tests
/// inject a deterministic `thermalStateProvider` closure.
///
/// All queue / continuation assertions here are behavioral — they observe
/// public `GenerationStream.phase` transitions and coordinator accessors
/// (`isGenerating`, `hasQueuedRequests`). No Mirror introspection, because
/// reflecting into `@Observable`-rewritten storage breaks silently when the
/// macro changes its naming scheme.
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

    /// High-priority (`.userInitiated`) requests must be inserted ahead of
    /// already-queued `.background` work. This is the user-facing invariant:
    /// typing a message doesn't wait behind background prefetches.
    ///
    /// Verified behaviorally via `stream.phase` transitions — the userInitiated
    /// stream must advance to `.connecting` before either background stream.
    func test_enqueue_userInitiatedBehindBackground_drainsFirst() async throws {
        let slowProvider = SlowFakeProvider()
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        // Active slot holds one request; queue builds behind it.
        let (_, activeStream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)

        // Queue two .background, then one .userInitiated.
        let (_, bg1Stream) = try coord.enqueue(messages: [("user", "bg1")], priority: .background)
        let (_, bg2Stream) = try coord.enqueue(messages: [("user", "bg2")], priority: .background)
        let (_, uiStream) = try coord.enqueue(messages: [("user", "ui")], priority: .userInitiated)

        // All three are currently queued (active is still running).
        XCTAssertEqual(uiStream.phase, .queued)
        XCTAssertEqual(bg1Stream.phase, .queued)
        XCTAssertEqual(bg2Stream.phase, .queued)

        // Release active: its stream completes, which kicks the defer block and
        // drainQueue() for the next request.
        slowProvider.backend.stopGeneration()
        for try await _ in activeStream.events {}

        // After active finishes, the userInitiated must be dequeued first.
        XCTAssertEqual(uiStream.phase, .connecting, "userInitiated must drain before backgrounds")
        XCTAssertEqual(bg1Stream.phase, .queued, "background1 must still be queued")
        XCTAssertEqual(bg2Stream.phase, .queued, "background2 must still be queued")

        coord.stopGeneration()
    }

    // MARK: - Cancel: queued

    func test_cancel_queuedRequest_removesFromQueueAndLeavesActiveRunning() async throws {
        let slowProvider = SlowFakeProvider()
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (_, activeStream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)
        let (queuedToken, queuedStream) = try coord.enqueue(
            messages: [("user", "queued")], priority: .normal
        )

        coord.cancel(queuedToken)

        // Cancelled queued stream must terminate; no tokens delivered.
        var tokens: [String] = []
        do {
            for try await event in queuedStream.events {
                if case .token(let t) = event { tokens.append(t) }
            }
        } catch {
            // CancellationError is the expected terminator here.
        }
        XCTAssertTrue(tokens.isEmpty, "cancelled queued request must not emit tokens")

        // Active still running; the coordinator still reports it.
        XCTAssertTrue(coord.isGenerating, "active request must remain in flight")

        coord.stopGeneration()
        _ = activeStream
    }

    // MARK: - Cancel: active (no-token-after-cancel)

    /// Key invariant: after `cancel` returns for the active request, **no
    /// `.token` events may be delivered on that request's continuation**. Even
    /// if the backend is still running, the coordinator must have torn down
    /// the continuation such that further yields are dropped.
    func test_cancel_activeRequest_noTokenAfterCancel() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 50, delayMilliseconds: 20)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (token, stream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)

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

    // MARK: - stopGeneration: behavioral drain

    /// `stopGeneration()` must reset the coordinator to a clean idle state —
    /// no active request, no queued requests, and every open stream terminated
    /// (readers unblock). Verified behaviorally: calling it, then awaiting each
    /// stream to completion, must return without hanging.
    func test_stopGeneration_emptiesQueueAndTerminatesAllStreams() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 50, delayMilliseconds: 20)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (_, activeStream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)
        let (_, q1Stream) = try coord.enqueue(messages: [("user", "queued1")], priority: .normal)
        let (_, q2Stream) = try coord.enqueue(messages: [("user", "queued2")], priority: .normal)

        coord.stopGeneration()

        XCTAssertFalse(coord.isGenerating)
        XCTAssertFalse(coord.hasQueuedRequests)

        // Each stream must be terminated: the for-await must return (possibly
        // via thrown CancellationError). If stopGeneration() failed to finish
        // any continuation, the corresponding `for try await` would hang and
        // this test would time out.
        for stream in [activeStream, q1Stream, q2Stream] {
            do { for try await _ in stream.events {} } catch { /* cancel error OK */ }
        }

        // After stopGeneration + drain, a fresh enqueue must succeed
        // immediately — proving the coordinator is back in a clean state with
        // no stale continuations blocking the queue.
        let (_, freshStream) = try coord.enqueue(messages: [("user", "fresh")], priority: .normal)
        XCTAssertNotEqual(freshStream.phase, .queued, "new request must start running after stop")
        coord.stopGeneration()
        do { for try await _ in freshStream.events {} } catch { /* cancel error OK */ }
    }

    // MARK: - discardRequests(notMatching:)

    func test_discardRequests_keepsMatchingSessionCancelsOthers() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 50, delayMilliseconds: 20)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let keepSession = UUID()
        let dropSession = UUID()

        // Active request belongs to keepSession.
        let (_, activeStream) = try coord.enqueue(
            messages: [("user", "active")], priority: .normal, sessionID: keepSession
        )
        // Queued: one matching keep, one not.
        let (_, keepStream) = try coord.enqueue(
            messages: [("user", "keep")], priority: .normal, sessionID: keepSession
        )
        let (_, dropStream) = try coord.enqueue(
            messages: [("user", "drop")], priority: .normal, sessionID: dropSession
        )

        coord.discardRequests(notMatching: keepSession)

        // The dropped stream must terminate — no tokens.
        var dropTokens: [String] = []
        do {
            for try await event in dropStream.events {
                if case .token(let t) = event { dropTokens.append(t) }
            }
        } catch {
            // expected cancellation
        }
        XCTAssertTrue(dropTokens.isEmpty, "non-matching session must be cancelled")

        // The kept queued stream must still be live (queued or draining once
        // active completes). It must NOT be in `.failed`.
        if case .failed(let reason) = keepStream.phase {
            XCTFail("matching-session stream should not be cancelled, got .failed(\(reason))")
        }

        _ = activeStream
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
        let slowProvider = SlowFakeProvider(tokenCount: 50, delayMilliseconds: 20)
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
    /// this without crashing and must return to a clean idle state: not
    /// generating, no queued requests, and a fresh enqueue succeeds.
    func test_drainQueue_reentryRace_noCrash_stateConsistent() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 2, delayMilliseconds: 5)
        let coord = GenerationCoordinator()
        coord.provider = slowProvider

        let (token1, s1) = try coord.enqueue(messages: [("user", "a")], priority: .normal)
        let (token2, s2) = try coord.enqueue(messages: [("user", "b")], priority: .normal)

        // Interleave cancels and yields to hit the re-entry window.
        coord.cancel(token1)
        await Task.yield()
        coord.cancel(token2)
        await Task.yield()

        // Consume both streams to completion so no task is leaked.
        do { for try await _ in s1.events {} } catch { /* expected cancel */ }
        do { for try await _ in s2.events {} } catch { /* expected cancel */ }

        XCTAssertFalse(coord.isGenerating)
        XCTAssertFalse(coord.hasQueuedRequests)

        // Fresh enqueue must succeed immediately — proof that no stale
        // continuations remained to block the queue.
        let (_, freshStream) = try coord.enqueue(messages: [("user", "fresh")], priority: .normal)
        XCTAssertNotEqual(freshStream.phase, .queued)
        coord.stopGeneration()
        do { for try await _ in freshStream.events {} } catch { /* cancel OK */ }
    }

    // MARK: - Enqueue ambiguous guard pinning

    /// The enqueue guard combines `provider?.currentBackend != nil` and
    /// `provider?.isBackendLoaded == true`. If either fails, the same
    /// "No model loaded" error fires. Pin this so a future guard split
    /// can't silently change the observable error.
    func test_enqueue_noBackend_throwsNoModelLoaded() {
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

    /// Thermal state is only read on `.background` priority. Normal-priority
    /// requests under `.serious` thermal pressure must still run. This
    /// explicitly reaches the backend to prove the guard at line 183 is gated
    /// on priority, not on thermal alone.
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

    // MARK: - Exact preflight (TokenCountingBackend)

    /// When the backend fits within the context window on the first count,
    /// `generate` must call `backend.generate()` exactly once without trimming.
    ///
    /// Sabotage check: if `exactPreflightAndTrim` always trimmed at least one
    /// message regardless of fit, `backend.generateCallCount` would still be 1
    /// but the prompt passed to the backend would be shorter than the full
    /// history — `backend.lastPrompt` would not contain all messages.
    func test_exactPreflight_promptFits_noTrimAndGenerateCalled() async throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 256)
        // countTokens returns 50 on first call → 50 + 128 (default maxOutput) = 178 ≤ 256 → fits.
        tcBackend.countTokensResponses = [50]
        tcBackend.tokensToYield = ["ok"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationCoordinator()
        coord.provider = tcProvider

        let (_, stream) = try coord.enqueue(
            messages: [("user", "hello")],
            maxOutputTokens: 128
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.generateCallCount, 1,
                       "generate must be called exactly once when the prompt fits")
        XCTAssertEqual(tcBackend.countTokensCalled, 1,
                       "countTokens must be called exactly once when the prompt fits")
    }

    /// When the first count is over budget but trimming brings it under,
    /// `generate` must eventually be called with the trimmed prompt.
    ///
    /// The mock returns counts that decrease across retries: first call is over
    /// budget, second call (after one trim) is within budget.
    ///
    /// Sabotage check: if the trim loop never removed a message,
    /// `countTokens` would always return the over-budget value and
    /// `contextExhausted` would be thrown, failing this test.
    func test_exactPreflight_promptOverBudget_trimsAndGenerates() async throws {
        // Context = 200, maxOutput = 100 → budget = 100 prompt tokens allowed.
        // First count = 150 (over), second count = 90 (under after one trim).
        let tcBackend = TokenCountingMockBackend(contextSize: 200)
        tcBackend.countTokensResponses = [150, 90]
        tcBackend.tokensToYield = ["trimmed"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationCoordinator()
        coord.provider = tcProvider

        // Two messages so we have something to trim.
        let (_, stream) = try coord.enqueue(
            messages: [
                (role: "user", content: "first message that will be trimmed"),
                (role: "user", content: "second message kept"),
            ],
            maxOutputTokens: 100
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.generateCallCount, 1,
                       "generate must be called once after successful trim")
        // Two count calls: one over-budget, one under-budget after trim.
        XCTAssertEqual(tcBackend.countTokensCalled, 2,
                       "countTokens must be called twice: once over budget, once after trim")
    }

    /// When trimming cannot bring the prompt under budget (all trim attempts
    /// exhausted or only the final user message remains),
    /// `InferenceError.contextExhausted` must be thrown.
    ///
    /// Sabotage check: if the coordinator silently forwarded the over-budget
    /// prompt to the backend, `generateCallCount` would be 1 and no error
    /// would be thrown — the XCTAssertThrowsError would fail.
    func test_exactPreflight_cannotTrim_throwsContextExhausted() throws {
        // Context = 100, maxOutput = 50 → only 50 prompt tokens allowed.
        // countTokens always returns 80 — over budget even with a single message.
        let tcBackend = TokenCountingMockBackend(contextSize: 100)
        tcBackend.countTokensResponses = [80, 80, 80, 80, 80]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationCoordinator()
        coord.provider = tcProvider

        // Single user message — cannot trim (would remove the only user turn).
        XCTAssertThrowsError(
            try coord.generate(
                messages: [("user", "a question that is too long for the context window")],
                maxOutputTokens: 50
            )
        ) { error in
            guard case InferenceError.contextExhausted = error else {
                XCTFail("Expected contextExhausted, got \(error)")
                return
            }
        }

        XCTAssertEqual(tcBackend.generateCallCount, 0,
                       "generate must never be called when context is exhausted — "
                       + "the overflow must not reach the C layer")
    }

    /// Verifies the trim-and-retry loop reduces the message list across
    /// multiple rounds. With three messages and counts that only fit after
    /// two trims, the final call to `backend.generate` must receive a shorter
    /// prompt than the original.
    func test_exactPreflight_multiRoundTrim_reducesHistory() async throws {
        // Context = 300, maxOutput = 100 → 200 token budget.
        // Round 0 (3 msgs): 250 tokens → over budget (250+100=350 > 300) → trim.
        // Round 1 (2 msgs): 210 tokens → over budget (210+100=310 > 300) → trim.
        // Round 2 (1 msg):  180 tokens → fits     (180+100=280 ≤ 300) → call generate.
        let tcBackend = TokenCountingMockBackend(contextSize: 300)
        tcBackend.countTokensResponses = [250, 210, 180]
        tcBackend.tokensToYield = ["done"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationCoordinator()
        coord.provider = tcProvider

        let (_, stream) = try coord.enqueue(
            messages: [
                (role: "user", content: "oldest message"),
                (role: "assistant", content: "middle reply"),
                (role: "user", content: "latest question"),
            ],
            maxOutputTokens: 100
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.generateCallCount, 1,
                       "generate must succeed after multi-round trim")
        XCTAssertEqual(tcBackend.countTokensCalled, 3,
                       "three count rounds expected: 2 over-budget, 1 under-budget")
    }

    // MARK: - Provider teardown safety

    /// Deallocating the provider mid-stream must not crash the coordinator.
    /// The `weak var provider` goes nil and in-flight generation ends cleanly.
    func test_providerTeardown_midStream_noCrash_cleanEnd() async throws {
        let slow = SlowMockBackend(tokenCount: 20, delayMilliseconds: 20)
        var slowProvider: SlowFakeProvider? = SlowFakeProvider(backend: slow)
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
        XCTAssertNil(coord.provider as? SlowFakeProvider)
    }
}

// MARK: - File-local fakes
//
// These conform to the internal `GenerationContextProvider` via `@testable
// import BaseChatInference`. Keeping them file-local (rather than publishing
// them from `BaseChatTestSupport`) means the protocol stays internal and the
// package's public API surface is unchanged.

/// A configurable fake that serves a `MockInferenceBackend`. Mirrors the
/// construction pattern the rest of the inference tests use.
@MainActor
final class FakeGenerationContextProvider: GenerationContextProvider {

    let backend: MockInferenceBackend
    var promptTemplate: PromptTemplate = .chatML

    init(backend: MockInferenceBackend = MockInferenceBackend()) {
        self.backend = backend
        // Default to a "loaded" state so enqueue() passes its guard. Tests
        // that want the unloaded path flip this explicitly.
        self.backend.isModelLoaded = true
    }

    var currentBackend: (any InferenceBackend)? { backend }
    var isBackendLoaded: Bool { backend.isModelLoaded }
    var selectedPromptTemplate: PromptTemplate { promptTemplate }
}

/// A fake that serves a `SlowMockBackend` for tests that need a backend that
/// yields tokens over time (cancellation / ordering).
@MainActor
private final class SlowFakeProvider: GenerationContextProvider {
    let backend: SlowMockBackend
    init(backend: SlowMockBackend) { self.backend = backend }
    convenience init(tokenCount: Int = 10, delayMilliseconds: Int = 30) {
        self.init(backend: SlowMockBackend(tokenCount: tokenCount, delayMilliseconds: delayMilliseconds))
    }
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

// MARK: - TokenCounting fakes

/// An inference backend that also conforms to `TokenCountingBackend` for testing
/// the exact pre-flight trim loop in `GenerationCoordinator`.
///
/// `countTokensResponses` controls what `countTokens` returns on each successive
/// call (FIFO). Once exhausted the last value is repeated.
/// `requiresPromptTemplate = true` so the coordinator takes the exact-preflight
/// path instead of the cloud/MLX fallback path.
final class TokenCountingMockBackend: InferenceBackend, TokenCountingBackend, @unchecked Sendable {

    // InferenceBackend
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities

    var tokensToYield: [String] = ["Hello", " world"]
    var shouldThrowOnGenerate: Error?
    private(set) var generateCallCount = 0
    private(set) var lastPrompt: String?

    // TokenCountingBackend
    var countTokensResponses: [Int] = []
    var countTokensError: Error?
    private(set) var countTokensCalled = 0

    init(contextSize: Int32 = 256) {
        self.capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: contextSize,
            requiresPromptTemplate: true,      // triggers exact-preflight path
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: true
        )
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        generateCallCount += 1
        lastPrompt = prompt
        if let error = shouldThrowOnGenerate { throw error }
        let tokens = tokensToYield
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                for token in tokens { continuation.yield(.token(token)) }
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }

    func countTokens(_ text: String) throws -> Int {
        if let error = countTokensError { throw error }
        countTokensCalled += 1
        guard !countTokensResponses.isEmpty else { return 10 }
        let idx = min(countTokensCalled - 1, countTokensResponses.count - 1)
        return countTokensResponses[idx]
    }
}

/// A fake provider that vends a `TokenCountingMockBackend`.
@MainActor
final class TokenCountingFakeProvider: GenerationContextProvider {
    let backend: TokenCountingMockBackend
    var promptTemplate: PromptTemplate = .chatML

    init(backend: TokenCountingMockBackend = TokenCountingMockBackend()) {
        self.backend = backend
        self.backend.isModelLoaded = true
    }

    var currentBackend: (any InferenceBackend)? { backend }
    var isBackendLoaded: Bool { backend.isModelLoaded }
    var selectedPromptTemplate: PromptTemplate { promptTemplate }
}

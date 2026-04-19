#if MLX
import XCTest
import MLXLMCommon
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

// Conform MockMLXModelContainer to the internal protocol in this test target,
// where both the internal protocol and the public mock type are visible.
// Note: the conformance may already be declared in MLXBackendGenerationTests.swift;
// if so, remove the duplicate extension here and use that file's conformance.
// Using `extension MockMLXModelContainer: MLXModelContainerProtocol {}` in multiple
// files will trigger a Swift redeclaration error — this file omits it in favour of
// the existing declaration in MLXBackendGenerationTests.swift.

/// Unit tests verifying that `MLXBackend` correctly routes thinking events through
/// `ThinkingParser` when `config.thinkingMarkers` is set.
///
/// Uses `MockMLXModelContainer` so no Metal / Apple Silicon hardware is required.
final class MLXBackendThinkingTests: XCTestCase {

    // MARK: - Helpers

    /// Drains all `.token` events from a `GenerationStream`.
    private func collectTokens(from stream: GenerationStream) async throws -> [String] {
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event { tokens.append(text) }
        }
        return tokens
    }

    /// Drains all `.thinkingToken` events from a `GenerationStream`.
    private func collectThinkingTokens(from stream: GenerationStream) async throws -> [String] {
        var tokens: [String] = []
        for try await event in stream.events {
            if case .thinkingToken(let text) = event { tokens.append(text) }
        }
        return tokens
    }

    /// Drains all events from a `GenerationStream` into an ordered array.
    private func collectAllEvents(from stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    // MARK: - Helpers for config

    private func thinkingConfig() -> GenerationConfig {
        GenerationConfig(thinkingMarkers: .qwen3)
    }

    // MARK: - 1. Thinking tokens emitted separately from visible tokens

    func test_thinkingTokensEmittedSeparatelyFromVisibleTokens() async throws {
        let mock = MockMLXModelContainer()
        // The mock yields raw token strings; MLXBackend passes them through ThinkingParser
        // when config.thinkingMarkers is non-nil.
        mock.tokensToYield = ["<think>", "reason", "</think>", "answer"]

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: thinkingConfig()
        )

        let allEvents = try await collectAllEvents(from: stream)

        // Verify thinking token appears
        let thinkingTexts = allEvents.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        XCTAssertFalse(thinkingTexts.isEmpty,
            "At least one .thinkingToken event must be emitted for content inside <think>…</think>")
        XCTAssertTrue(thinkingTexts.joined().contains("reason"),
            ".thinkingToken events must contain the reasoning content")

        // Verify .thinkingComplete fires
        let completions = allEvents.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }
        XCTAssertEqual(completions.count, 1,
            "Exactly one .thinkingComplete must fire when </think> is encountered")

        // Verify visible token appears
        let visibleTexts = allEvents.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertTrue(visibleTexts.joined().contains("answer"),
            "Content after </think> must be emitted as .token events")

        // Verify ordering: all thinkingToken events before thinkingComplete before token events
        let firstThinkingIndex = allEvents.firstIndex {
            if case .thinkingToken = $0 { return true } else { return false }
        }
        let completeIndex = allEvents.firstIndex {
            if case .thinkingComplete = $0 { return true } else { return false }
        }
        let firstTokenIndex = allEvents.firstIndex {
            if case .token = $0 { return true } else { return false }
        }

        if let ti = firstThinkingIndex, let ci = completeIndex, let vi = firstTokenIndex {
            XCTAssertLessThan(ti, ci, ".thinkingToken events must precede .thinkingComplete")
            XCTAssertLessThan(ci, vi, ".thinkingComplete must precede .token events")
        } else {
            XCTFail("Expected all three event types in the stream")
        }

        // Sabotage check: setting config.thinkingMarkers = nil would bypass ThinkingParser,
        // causing raw "<think>" text to appear as .token events and failing the thinkingTexts check.
    }

    // MARK: - 2. outputTokenCount does not include thinking tokens

    func test_outputTokenCount_doesNotIncludeThinkingTokens() async throws {
        let mock = MockMLXModelContainer()
        // 3 thinking tokens + 1 visible token; maxOutputTokens = 1 should allow exactly 1 .token
        mock.tokensToYield = ["<think>", "a", "b", "</think>", "answer", "more"]

        let backend = MLXBackend()
        backend._inject(mock)

        var config = thinkingConfig()
        config.maxOutputTokens = 1

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: config
        )

        let allEvents = try await collectAllEvents(from: stream)

        let visibleTokens = allEvents.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }

        // With maxOutputTokens=1, only the first visible token should be emitted.
        // Thinking tokens must not count toward this limit.
        XCTAssertEqual(visibleTokens.count, 1,
            "maxOutputTokens must count only .token events, not .thinkingToken events")
        XCTAssertEqual(visibleTokens.first, "answer",
            "The first visible token after the thinking block should be 'answer'")

        // Thinking content must still have been emitted (budget was not consumed by it)
        let thinkingTexts = allEvents.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        XCTAssertFalse(thinkingTexts.isEmpty,
            "Thinking tokens must still be emitted even when maxOutputTokens=1")

        // Sabotage check: if thinking tokens incremented outputTokenCount, the limit
        // would be hit mid-thinking-block and "answer" would never appear as a .token.
    }

    // MARK: - 3. No thinking events without markers

    func test_noThinkingEvents_whenMarkersNotSet() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["<think>", "reason", "</think>", "answer"]

        let backend = MLXBackend()
        backend._inject(mock)

        // config.thinkingMarkers = nil → ThinkingParser disabled
        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()  // no thinkingMarkers
        )

        let allEvents = try await collectAllEvents(from: stream)

        let thinkingEvents = allEvents.filter {
            if case .thinkingToken = $0 { return true }
            if case .thinkingComplete = $0 { return true }
            return false
        }
        XCTAssertTrue(thinkingEvents.isEmpty,
            "When config.thinkingMarkers is nil, no .thinkingToken or .thinkingComplete events must be emitted")

        let rawTokens = allEvents.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertTrue(rawTokens.joined().contains("<think>"),
            "Raw <think> tag must pass through as .token when ThinkingParser is disabled")

        // Sabotage check: always running ThinkingParser regardless of config.thinkingMarkers
        // would produce .thinkingToken events here and fail the thinkingEvents.isEmpty check.
    }

    // MARK: - 4. Custom (non-qwen3) thinking markers route through ThinkingParser (#513)

    /// Verifies that `ThinkingMarkers.custom(open:close:)` — the extensibility hook for
    /// non-Qwen3 reasoning formats (GPT-OSS `<|channel|>`, Gemma 4 variants, etc.) —
    /// drives the MLX ThinkingParser the same way `.qwen3` does.
    ///
    /// `MLXBackendThinkingTests` only exercised the qwen3 tag pair before this fixture,
    /// so any future marker variant would have landed against untested code.
    func test_customMarkers_routeThroughParser() async throws {
        let mock = MockMLXModelContainer()
        // GPT-OSS-style channel markers (representative non-qwen3 pair).
        let markers = ThinkingMarkers.custom(open: "<|channel|>analysis", close: "<|channel|>final")
        // Interleave enough whitespace to keep the ThinkingParser's holdback buffer
        // small and predictable; the parser treats the open/close markers as opaque
        // substrings regardless of the surrounding whitespace.
        mock.tokensToYield = [
            "<|channel|>analysis", " hmm ", "<|channel|>final", " answer"
        ]

        let backend = MLXBackend()
        backend._inject(mock)

        var config = GenerationConfig()
        config.thinkingMarkers = markers

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: config
        )

        let allEvents = try await collectAllEvents(from: stream)

        // The reasoning content between the custom open/close markers must route through
        // .thinkingToken, not raw .token, proving the config-passed markers reach the parser.
        let thinkingTexts = allEvents.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        XCTAssertFalse(thinkingTexts.isEmpty,
            "Custom markers must produce at least one .thinkingToken event for content between them")
        XCTAssertTrue(thinkingTexts.joined().contains("hmm"),
            "The reasoning body (\"hmm\") must appear inside .thinkingToken events, not raw .token events")

        // Exactly one .thinkingComplete at the close marker.
        let completions = allEvents.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }
        XCTAssertEqual(completions.count, 1,
            "Exactly one .thinkingComplete must fire when the custom close marker is encountered")

        // Post-close content must emerge as visible .token events.
        let visibleTexts = allEvents.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertTrue(visibleTexts.joined().contains("answer"),
            "Content after the custom close marker must be emitted as .token events")

        // The raw open/close marker strings must NOT leak into visible token output.
        XCTAssertFalse(visibleTexts.joined().contains("<|channel|>"),
            "Custom open/close marker bytes must be consumed by the parser, not leaked as .token text")

        // Sabotage check: swapping `config.thinkingMarkers = markers` for `= .qwen3` would
        // stop the parser from recognising the `<|channel|>` pair; the whole stream would
        // surface as raw .token events and thinkingTexts.isEmpty would fail.
    }

    // MARK: - 5. maxThinkingTokens parity with LlamaGenerationDriver (#514)

    /// Verifies that `GenerationConfig.maxThinkingTokens` terminates MLX generation the
    /// same way it does in `LlamaGenerationDriver`.
    ///
    /// Today `MLXBackend.generate` does NOT track or enforce the thinking-token budget —
    /// the test is skipped with a pointer to the backend gap so the divergence is visible
    /// in the CI output rather than silently ignored.
    func test_maxThinkingTokens_terminatesGeneration_parity_with_llama() async throws {
        // FIXME: unskip when MLXBackend honours config.maxThinkingTokens
        // (tracked in https://github.com/roryford/BaseChatKit/issues/550).
        //
        // Target assertions, enabled once the backend fix lands:
        //
        //   let mock = MockMLXModelContainer()
        //   mock.tokensToYield = ["<think>", "a", "b", "c", "d", "</think>", "answer"]
        //   let backend = MLXBackend()
        //   backend._inject(mock)
        //   var config = GenerationConfig(thinkingMarkers: .qwen3)
        //   config.maxThinkingTokens = 2
        //   let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        //   let events = try await collectAllEvents(from: stream)
        //   let thinkingTokens = events.compactMap { ev -> String? in
        //       if case .thinkingToken(let t) = ev { return t } else { return nil }
        //   }
        //   let visibleTokens = events.compactMap { ev -> String? in
        //       if case .token(let t) = ev { return t } else { return nil }
        //   }
        //   XCTAssertLessThanOrEqual(thinkingTokens.count, 2)
        //   XCTAssertFalse(visibleTokens.joined().contains("answer"))
        //
        // Sabotage check once unskipped: raising maxThinkingTokens to 10 would let every
        // thinking token and the full "answer" token through, failing both assertions.
        throw XCTSkip(
            "MLXBackend does not yet enforce maxThinkingTokens; see issue #550 for the backend fix. " +
            "Fixture lands today so the parity gap with LlamaGenerationDriver is documented."
        )
    }
}
#endif

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
}
#endif

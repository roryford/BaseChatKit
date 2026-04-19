#if MLX
import XCTest
import MLXLMCommon
import BaseChatCore
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

// Conform MockMLXModelContainer to the internal protocol in this test target,
// where both the internal protocol and the public mock type are visible.
extension MockMLXModelContainer: MLXModelContainerProtocol {}

/// Unit tests for `MLXBackend.generate()` using `MockMLXModelContainer`.
///
/// These tests run in CI without Apple Silicon — the generation path is driven
/// entirely by the injected mock which never touches the Metal GPU stack.
/// `test_sendableLMInput_wrapsAndUnwraps` is limited to compile-time/type-level
/// wrapping checks and does not perform an MLX/Metal runtime round trip.
final class MLXBackendGenerationTests: XCTestCase {

    // MARK: - Helpers

    /// Drains all `.token` events from a `GenerationStream` into an ordered array.
    private func collectTokens(
        from stream: GenerationStream
    ) async throws -> [String] {
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }
        return tokens
    }

    // MARK: - test_generate_yieldsInjectedTokens

    func test_generate_yieldsInjectedTokens() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["Hello", " world"]

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let tokens = try await collectTokens(from: stream)

        XCTAssertEqual(tokens, ["Hello", " world"],
            "Stream must yield exactly the injected tokens in order")
        XCTAssertEqual(mock.generateCallCount, 1)

        // Verify the messages were assembled with user role.
        XCTAssertEqual(mock.lastMessages?.last?["role"], "user")
        XCTAssertEqual(mock.lastMessages?.last?["content"], "hi")

        // Sabotage check: tokensToYield = [] would produce an empty array,
        // failing the equality assertion.
    }

    // MARK: - test_generate_respectsMaxOutputTokens

    func test_generate_respectsMaxOutputTokens() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]

        let backend = MLXBackend()
        backend._inject(mock)

        var config = GenerationConfig()
        config.maxOutputTokens = 3

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: config
        )

        let tokens = try await collectTokens(from: stream)

        XCTAssertEqual(tokens.count, 3,
            "Backend must stop yielding after maxOutputTokens tokens")
        XCTAssertEqual(tokens, ["A", "B", "C"])

        // Sabotage check: setting maxOutputTokens = 100 yields all 10 tokens,
        // causing the count assertion to fail.
    }

    // MARK: - test_generate_cancellation

    func test_generate_cancellation() async throws {
        let mock = MockMLXModelContainer()
        // Use many tokens so the stream is still live when we cancel.
        mock.tokensToYield = Array(repeating: "x", count: 50)

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // Consume one token, then break to cancel the stream.
        var receivedCount = 0
        for try await event in stream.events {
            if case .token = event {
                receivedCount += 1
                if receivedCount == 1 { break }
            }
        }

        // The stream's onTermination fires task.cancel() which sets isGenerating = false
        // asynchronously in the @MainActor task. Poll with a tight deadline.
        let expectation = expectation(description: "isGenerating clears after cancel")
        Task {
            let deadline = ContinuousClock.now + .seconds(2)
            while backend.isGenerating, ContinuousClock.now < deadline {
                await Task.yield()
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 3)

        XCTAssertFalse(backend.isGenerating,
            "isGenerating must be false after the stream is cancelled")
        XCTAssertEqual(receivedCount, 1,
            "Should have consumed exactly one token before cancelling")

        // Sabotage check: removing the break would drain the full stream, making
        // isGenerating false for the wrong reason (completion, not cancellation).
    }

    // MARK: - test_generate_generateThrows_propagatesError

    func test_generate_generateThrows_propagatesError() async throws {
        struct GenerateFailure: Error {}

        let mock = MockMLXModelContainer()
        mock.generateError = GenerateFailure()

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // Drain the stream — the thrown error surfaces via the events stream.
        var didThrow = false
        do {
            for try await _ in stream.events {}
        } catch {
            didThrow = true
            XCTAssertTrue(error is GenerateFailure, "Expected GenerateFailure, got \(error)")
        }

        XCTAssertTrue(didThrow, "Stream must propagate the error thrown by generate")

        // Verify the GenerationStream reached the .failed phase.
        let phase = await MainActor.run { stream.phase }
        if case .failed = phase {
            // Expected.
        } else {
            XCTFail("Expected stream phase .failed, got \(phase)")
        }

        // Sabotage check: removing mock.generateError leaves generateError as nil,
        // so the stream succeeds and didThrow stays false, failing the assertion.
    }

    // MARK: - test_sendableLMInput_wrapsAndUnwraps

    // MARK: - Stop reason surfacing (#515)

    /// Helper: drains every event (token, thinking, usage, tool-call) into an ordered array.
    private func collectAllEvents(
        from stream: GenerationStream
    ) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    /// Documents today's conflation: both natural end-of-stream AND `maxOutputTokens`
    /// cutoff collapse to `GenerationStream.Phase.done` with no dedicated
    /// "stop_reason" signal. Downstream UI that wants to render "response truncated"
    /// today has nothing to key off.
    ///
    /// The fixture drives both paths in a single test so the shared baseline assertion
    /// ("all terminations look identical today") is written once. When structured
    /// stop reasons land (GenerationEvent.stopReason(.endOfStream / .maxTokens)), flip
    /// the per-branch assertions to the target shape — see FIXMEs inline.
    func test_stopReason_today_collapsesToDone_forBothNaturalAndMaxTokens() async throws {
        // MARK: Natural EOS — mock finishes its finite token list
        do {
            let mock = MockMLXModelContainer()
            mock.tokensToYield = ["Hi", "."]

            let backend = MLXBackend()
            backend._inject(mock)

            let stream = try backend.generate(
                prompt: "hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )

            let events = try await collectAllEvents(from: stream)
            let tokens = events.compactMap { ev -> String? in
                if case .token(let t) = ev { return t } else { return nil }
            }
            XCTAssertEqual(tokens, ["Hi", "."],
                "Natural EOS must surface every injected token before termination")

            // FIXME: when GenerationEvent gains `.stopReason(.endOfStream)`
            // (tracked in https://github.com/roryford/BaseChatKit/issues/515),
            // replace the .done phase check with an assertion on the final event.
            let phase = await MainActor.run { stream.phase }
            if case .done = phase {
                // Expected today.
            } else {
                XCTFail("Expected .done phase on natural EOS, got \(phase)")
            }
        }

        // MARK: Hit maxOutputTokens — same .done phase, no structured distinction
        do {
            let mock = MockMLXModelContainer()
            mock.tokensToYield = Array(repeating: "x", count: 50)

            let backend = MLXBackend()
            backend._inject(mock)

            var config = GenerationConfig()
            config.maxOutputTokens = 3

            let stream = try backend.generate(
                prompt: "hi",
                systemPrompt: nil,
                config: config
            )

            let events = try await collectAllEvents(from: stream)
            let tokens = events.compactMap { ev -> String? in
                if case .token(let t) = ev { return t } else { return nil }
            }
            XCTAssertEqual(tokens.count, 3,
                "maxOutputTokens must cap visible tokens — this is the truncation the UI cares about")

            // FIXME: when GenerationEvent gains `.stopReason(.maxTokens)`
            // (tracked in https://github.com/roryford/BaseChatKit/issues/515),
            // flip this to XCTAssertEqual(stopReasons.last, .maxTokens) so the UI
            // can distinguish a truncated response from a natural stop.
            let phase = await MainActor.run { stream.phase }
            if case .done = phase {
                // Expected today — the conflation this fixture exists to flag.
            } else {
                XCTFail("Expected .done phase on maxOutputTokens cutoff, got \(phase)")
            }
        }

        // Sabotage check: changing the first mock.tokensToYield to ["Hi"] makes the
        // natural-EOS branch's XCTAssertEqual(tokens, ["Hi", "."]) fail. Raising the
        // second branch's maxOutputTokens to 100 breaks the tokens.count == 3 check.
    }

    // MARK: - Tool call deltas (deferred — #517)

    /// Documents today's tool-call leak: when a qwen3-style `<tool_call>…</tool_call>`
    /// block appears in the raw MLX stream, `MLXBackend` passes it through as plain
    /// `.token` events because `capabilities.supportsToolCalling = false` and no
    /// tool-call extraction logic exists yet.
    ///
    /// This failing-contract fixture asserts the target event shape (`.toolCallStart`,
    /// `.toolCall`-delta, `.toolCallEnd`) so the first implementation has a concrete
    /// target. Skipped today because the target `GenerationEvent` cases do not exist.
    func test_toolCallDeltas_extractedFromStream() async throws {
        // FIXME: unskip when GenerationEvent gains `.toolCallStart` / `.toolCallDelta` /
        // `.toolCallEnd` cases (tracked in https://github.com/roryford/BaseChatKit/issues/517).
        //
        // Target assertions, enabled once the backend extracts tool-call deltas:
        //
        //   let mock = MockMLXModelContainer()
        //   mock.tokensToYield = [
        //       "<tool_call>",
        //       "{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}",
        //       "</tool_call>"
        //   ]
        //   let backend = MLXBackend()
        //   backend._inject(mock)
        //   let stream = try backend.generate(prompt: "weather?", systemPrompt: nil,
        //                                     config: GenerationConfig())
        //   let events = try await collectAllEvents(from: stream)
        //   let visibleTokens = events.compactMap { ev -> String? in
        //       if case .token(let t) = ev { return t } else { return nil }
        //   }
        //   XCTAssertFalse(visibleTokens.joined().contains("<tool_call>"),
        //       "tool_call tags must not leak into visible .token output")
        //   XCTAssertTrue(events.contains(where: {
        //       if case .toolCall(let call) = $0, call.name == "get_weather" { return true }
        //       return false
        //   }), "A .toolCall event naming get_weather must surface")
        //
        // Sabotage check once unskipped: delete the extractor code path so the raw
        // `<tool_call>` bytes leak back into .token events, failing both assertions.
        throw XCTSkip(
            "MLXBackend does not yet extract tool-call deltas; see issue #517 for the feature work. " +
            "Fixture lands today so the first tool-calling implementation has a concrete target shape."
        )
    }

    // MARK: - Chat-template detection (#516)

    /// Covers the observable slice of MLX chat-template handling: the `messages`
    /// dictionary array the backend hands to the container, unchanged.
    ///
    /// The full detection matrix (missing `tokenizer_config.json`, template without an
    /// `<|assistant|>` marker) requires `MockMLXModelContainer` to expose a tokenizer
    /// hook — tracked in #551 — and is gated by `XCTSkip` until that lands.
    func test_chatTemplate_messagesPassThroughUnchanged() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]

        let backend = MLXBackend()
        backend._inject(mock)

        let systemPrompt = "You are helpful."
        let userPrompt = "hello"

        let stream = try backend.generate(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            config: GenerationConfig()
        )

        // Drain so the generate task completes and `lastMessages` is populated.
        _ = try await collectAllEvents(from: stream)

        // The backend hands the MLX container the [role:system, role:user] pair so the
        // real tokenizer's chat template can apply. A template missing `<|assistant|>`
        // will fail at tokenize time, not here — that branch is covered by the sibling
        // skip test below plus #551.
        let sent = try XCTUnwrap(mock.lastMessages,
            "MLXBackend.generate must pass a messages array to the container")
        XCTAssertEqual(sent.count, 2,
            "Expected [system, user] when both prompts are provided")
        XCTAssertEqual(sent.first?["role"], "system")
        XCTAssertEqual(sent.first?["content"], systemPrompt)
        XCTAssertEqual(sent.last?["role"], "user")
        XCTAssertEqual(sent.last?["content"], userPrompt)

        // Sabotage check: reordering the msgs.append calls in MLXBackend.generate would
        // flip system and user positions, failing the first/last XCTAssertEquals.

        // FIXME: extend this fixture with "missing chat template" and "template without
        // <|assistant|> marker" branches once MockMLXModelContainer exposes tokenizer
        // hooks (tracked in https://github.com/roryford/BaseChatKit/issues/551). The
        // pass-through assertion above is the only observable slice at unit-test scope
        // today — the full detection matrix is Metal-gated.
    }

    // MARK: - test_generate_usesConversationHistory

    func test_generate_usesConversationHistory() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]

        let backend = MLXBackend()
        backend._inject(mock)

        // Simulate two prior turns before the current user message.
        backend.setConversationHistory([
            ("user", "What is the capital of France?"),
            ("assistant", "Paris."),
            ("user", "And Germany?"),
        ])

        let stream = try backend.generate(
            prompt: "And Germany?",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        _ = try await collectTokens(from: stream)

        let sent = try XCTUnwrap(mock.lastMessages)
        XCTAssertEqual(sent.count, 3,
            "All three history turns must be forwarded to the container")
        XCTAssertEqual(sent[0]["role"], "user")
        XCTAssertEqual(sent[0]["content"], "What is the capital of France?")
        XCTAssertEqual(sent[1]["role"], "assistant")
        XCTAssertEqual(sent[1]["content"], "Paris.")
        XCTAssertEqual(sent[2]["role"], "user")
        XCTAssertEqual(sent[2]["content"], "And Germany?")

        // Sabotage check: removing the setConversationHistory call causes the
        // backend to fall back to the bare prompt path, producing a 1-element
        // messages array and failing the count assertion.
    }

    func test_sendableLMInput_wrapsAndUnwraps() throws {
        // This test verifies `SendableLMInput` at the type level: the wrapper must
        // satisfy Swift's `Sendable` requirement so the compiler allows cross-actor
        // transfer. The MLX runtime (Metal) is NOT accessed here.
        //
        // Full round-trip testing (with a real LMInput) requires Metal and is
        // exercised in BaseChatE2ETests on Apple Silicon hardware.

        // Verify that SendableLMInput is Sendable at compile time.
        // If the @unchecked Sendable annotation were removed, the compiler would
        // reject the line below with a Sendable violation.
        func assertSendable<T: Sendable>(_: T.Type) {}
        assertSendable(SendableLMInput.self)

        // Verify the wrapper's public surface at compile time without constructing
        // an LMInput: both the initializer and `.value` must be accessible.
        let initializer = SendableLMInput.init
        let valueKeyPath = \SendableLMInput.value
        _ = (initializer, valueKeyPath)
    }
}
#endif

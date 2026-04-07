#if MLX
import XCTest
import MLXLMCommon
import BaseChatCore
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

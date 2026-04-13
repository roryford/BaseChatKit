import XCTest
import BaseChatCore
import BaseChatInference
import BaseChatTestSupport

/// One assertion per failure mode on `ChaosBackend`. These tests lock in the
/// contract each mode promises to deliver so UI-layer regressions have a
/// stable fixture to point at.
final class ChaosBackendTests: XCTestCase {

    private let modelURL = URL(fileURLWithPath: "/tmp/fake-model")
    private let allTokens = ["a", "b", "c", "d", "e"]

    private func collect(_ backend: ChaosBackend) async -> (tokens: [String], error: Error?) {
        let stream: GenerationStream
        do {
            stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        } catch {
            return ([], error)
        }
        var collected: [String] = []
        do {
            for try await event in stream.events {
                if case .token(let t) = event { collected.append(t) }
            }
            return (collected, nil)
        } catch {
            return (collected, error)
        }
    }

    func test_noneMode_yieldsEverything() async throws {
        let backend = ChaosBackend(mode: .none, tokensToYield: allTokens)
        try await backend.loadModel(from: modelURL, contextSize: 512)
        let (tokens, error) = await collect(backend)
        XCTAssertNil(error)
        XCTAssertEqual(tokens, allTokens)
    }

    func test_dropMidStream_truncatesWithoutThrowing() async throws {
        let backend = ChaosBackend(mode: .dropMidStream(afterTokens: 2), tokensToYield: allTokens)
        try await backend.loadModel(from: modelURL, contextSize: 512)
        let (tokens, error) = await collect(backend)
        XCTAssertNil(error, "dropMidStream must silently finish, not throw")
        XCTAssertEqual(tokens, ["a", "b"])
    }

    func test_slowFirstToken_delaysBeforeFirstEvent() async throws {
        let delay: Duration = .milliseconds(50)
        let backend = ChaosBackend(mode: .slowFirstToken(delay: delay), tokensToYield: allTokens)
        try await backend.loadModel(from: modelURL, contextSize: 512)

        let clock = ContinuousClock()
        let start = clock.now
        let (tokens, error) = await collect(backend)
        let elapsed = start.duration(to: clock.now)

        XCTAssertNil(error)
        XCTAssertEqual(tokens, allTokens)
        XCTAssertGreaterThanOrEqual(
            elapsed, delay,
            "slowFirstToken must wait the configured delay before streaming"
        )
    }

    func test_burstThenStall_pausesMidStream() async throws {
        let stall: Duration = .milliseconds(50)
        let backend = ChaosBackend(
            mode: .burstThenStall(burstSize: 2, stallDuration: stall),
            tokensToYield: allTokens
        )
        try await backend.loadModel(from: modelURL, contextSize: 512)

        let clock = ContinuousClock()
        let start = clock.now
        let (tokens, error) = await collect(backend)
        let elapsed = start.duration(to: clock.now)

        XCTAssertNil(error)
        XCTAssertEqual(tokens, allTokens)
        XCTAssertGreaterThanOrEqual(
            elapsed, stall,
            "burstThenStall must include at least one stall period"
        )
    }

    func test_networkError_throwsAfterPartialStream() async throws {
        let backend = ChaosBackend(mode: .networkError(afterTokens: 3), tokensToYield: allTokens)
        try await backend.loadModel(from: modelURL, contextSize: 512)
        let (tokens, error) = await collect(backend)
        XCTAssertEqual(tokens, ["a", "b", "c"])
        XCTAssertNotNil(error, "networkError must surface an error on the stream")
        guard case .inferenceFailure = error as? InferenceError else {
            XCTFail("Expected InferenceError.inferenceFailure, got \(String(describing: error))")
            return
        }
    }
}

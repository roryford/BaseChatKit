import XCTest
import BaseChatCore

/// Shared conformance tests that verify the `stopGeneration()` contract
/// documented on `InferenceBackend`.
///
/// Any test target can call these helpers with a concrete backend instance
/// to verify it honours the protocol contract.
public enum StopGenerationContractTests {

    /// Verifies that `isGenerating` is `false` after `stopGeneration()` and
    /// that a subsequent `generate()` call succeeds cleanly.
    ///
    /// The backend must already have a model loaded before calling this.
    public static func verifyStopLeavesBackendReusable(
        _ backend: some InferenceBackend,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let config = GenerationConfig(maxTokens: 64)

        // 1. Start generation and immediately stop.
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: config
        )
        backend.stopGeneration()

        // 2. isGenerating must be false after stop.
        XCTAssertFalse(
            backend.isGenerating,
            "isGenerating must be false after stopGeneration()",
            file: file,
            line: line
        )

        // Drain the stream so the backend's internal task completes.
        for try await _ in stream {}

        // 3. A new generate() call must work without errors.
        let secondStream = try backend.generate(
            prompt: "World",
            systemPrompt: nil,
            config: config
        )

        var tokens: [String] = []
        for try await token in secondStream {
            tokens.append(token)
        }

        XCTAssertFalse(
            tokens.isEmpty,
            "Second generate() after stop must produce tokens",
            file: file,
            line: line
        )

        XCTAssertFalse(
            backend.isGenerating,
            "isGenerating must be false after second stream completes",
            file: file,
            line: line
        )
    }
}

import Foundation
import BaseChatCore

/// A mock backend that yields tokens with configurable delays, enabling
/// cancellation to be tested mid-stream.
///
/// Shared across test targets via BaseChatTestSupport.
public final class SlowMockBackend: InferenceBackend, @unchecked Sendable {
    public var isModelLoaded = true
    public var isGenerating = false
    public var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    public var tokensToYield: [String] = []
    public var delayPerToken: Duration = .milliseconds(50)

    public init() {}

    /// Convenience initialiser that sets an initial token list and a millisecond delay.
    ///
    /// - Parameters:
    ///   - tokenCount: Number of tokens to pre-populate (formatted as `"token0 "`, `"token1 "`, …).
    ///   - delayMilliseconds: Per-token delay in milliseconds (default: 50).
    public init(tokenCount: Int, delayMilliseconds: Int = 50) {
        tokensToYield = (0..<tokenCount).map { "token\($0) " }
        delayPerToken = .milliseconds(delayMilliseconds)
    }

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        isGenerating = true
        let tokens = tokensToYield
        let delay = delayPerToken

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                for token in tokens {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                self?.isGenerating = false
                continuation.finish()
            }
        }
    }

    public func stopGeneration() {
        isGenerating = false
    }

    public func unloadModel() {
        isModelLoaded = false
        isGenerating = false
    }
}

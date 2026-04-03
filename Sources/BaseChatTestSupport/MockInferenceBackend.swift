import Foundation
import BaseChatCore

/// Configurable mock inference backend for testing.
///
/// Shared across all test targets via the `BaseChatTestSupport` module.
public final class MockInferenceBackend: InferenceBackend, @unchecked Sendable {
    public var isModelLoaded: Bool = false
    public var isGenerating: Bool = false
    public var capabilities: BackendCapabilities

    // Configurable behavior
    public var tokensToYield: [String] = ["Hello", " world"]
    public var shouldThrowOnGenerate: Error? = nil
    public var shouldThrowOnLoad: Error? = nil

    // Track calls
    public var loadModelCallCount = 0
    public var generateCallCount = 0
    public var stopCallCount = 0
    public var unloadCallCount = 0

    // Capture last generate arguments
    public var lastPrompt: String?
    public var lastSystemPrompt: String?
    public var lastConfig: GenerationConfig?

    /// Stored so stopGeneration() can terminate the in-flight stream.
    private var activeContinuation: AsyncThrowingStream<String, Error>.Continuation?

    public init(capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: false,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )) {
        self.capabilities = capabilities
    }

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        loadModelCallCount += 1
        if let error = shouldThrowOnLoad { throw error }
        isModelLoaded = true
    }

    public func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> AsyncThrowingStream<String, Error> {
        generateCallCount += 1
        lastPrompt = prompt
        lastSystemPrompt = systemPrompt
        lastConfig = config
        if let error = shouldThrowOnGenerate { throw error }
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }

        isGenerating = true
        let tokens = tokensToYield

        return AsyncThrowingStream { [self] continuation in
            self.activeContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                self.activeContinuation = nil
            }
            Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                self.isGenerating = false
                continuation.finish()
            }
        }
    }

    public func stopGeneration() {
        stopCallCount += 1
        isGenerating = false
        activeContinuation?.finish()
        activeContinuation = nil
    }

    public func unloadModel() {
        unloadCallCount += 1
        isModelLoaded = false
        isGenerating = false
    }
}

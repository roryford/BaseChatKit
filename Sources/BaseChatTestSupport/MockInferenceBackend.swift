import Foundation
import Darwin
import BaseChatCore

/// Configurable mock inference backend for testing.
///
/// Shared across all test targets via the `BaseChatTestSupport` module.
public final class MockInferenceBackend: InferenceBackend, ConversationHistoryReceiver, @unchecked Sendable {
    public var isModelLoaded: Bool = false
    public var isGenerating: Bool = false
    public var capabilities: BackendCapabilities

    // Configurable behavior
    public var tokensToYield: [String] = ["Hello", " world"]
    public var shouldThrowOnGenerate: Error? = nil
    public var shouldThrowOnLoad: Error? = nil

    /// Error to throw INSIDE the stream after yielding all tokens.
    /// This simulates network/stream failures that real backends deliver
    /// via the AsyncThrowingStream rather than from generate() itself.
    public var shouldThrowInsideStream: Error?

    // Track calls
    public var loadModelCallCount = 0
    public var generateCallCount = 0
    public var stopCallCount = 0
    public var unloadCallCount = 0

    /// Records whether `loadModel` was called on the main thread.
    /// `nil` until `loadModel` has been called at least once.
    public var loadModelCalledOnMainThread: Bool?

    // Capture last generate arguments
    public var lastPrompt: String?
    public var lastSystemPrompt: String?
    public var lastConfig: GenerationConfig?

    /// Stored so stopGeneration() can terminate the in-flight stream.
    private var activeContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?

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
        loadModelCalledOnMainThread = pthread_main_np() != 0
        if let error = shouldThrowOnLoad { throw error }
        isModelLoaded = true
    }

    public func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> AsyncThrowingStream<GenerationEvent, Error> {
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
                    continuation.yield(.token(token))
                }
                self.isGenerating = false
                if let streamError = self.shouldThrowInsideStream, !Task.isCancelled {
                    continuation.finish(throwing: streamError)
                    return
                }
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

    // MARK: - ConversationHistoryReceiver

    public var lastReceivedHistory: [(role: String, content: String)]?

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        lastReceivedHistory = messages
    }
}

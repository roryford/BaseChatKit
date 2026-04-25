import Foundation
import Darwin
import BaseChatInference

/// Configurable mock inference backend for testing.
///
/// Shared across all test targets via the `BaseChatTestSupport` module.
public final class MockInferenceBackend: InferenceBackend, ConversationHistoryReceiver, @unchecked Sendable {
    public var isModelLoaded: Bool = false
    public var isGenerating: Bool = false
    public var capabilities: BackendCapabilities

    // Configurable behavior
    public var tokensToYield: [String] = ["Hello", " world"]
    public var thinkingTokensToYield: [String] = []
    public var shouldThrowOnGenerate: Error? = nil
    public var shouldThrowOnLoad: Error? = nil

    /// Error to throw INSIDE the stream after yielding all tokens.
    /// This simulates network/stream failures that real backends deliver
    /// via the AsyncThrowingStream rather than from generate() itself.
    public var shouldThrowInsideStream: Error?

    /// Tool calls to emit during generation, interleaved after all text tokens.
    ///
    /// When non-empty the backend emits all ``tokensToYield`` tokens first,
    /// then emits one ``GenerationEvent/toolCall(_:)`` event per entry in
    /// this array before finishing the stream.  This lets tests assert on
    /// the full stream event sequence without wiring up a real backend.
    public var scriptedToolCalls: [ToolCall] = []

    /// Per-turn tool calls for tests that exercise the orchestrator's
    /// tool-dispatch loop.
    ///
    /// Each call to ``generate(prompt:systemPrompt:config:)`` pops the first
    /// entry (its elements become `scriptedToolCalls` for that one call).
    /// When this queue is non-empty it takes precedence over the flat
    /// ``scriptedToolCalls`` property; once the queue is drained the backend
    /// emits no further tool calls even if ``scriptedToolCalls`` was seeded.
    /// This mirrors the real-world pattern where a model emits a tool call on
    /// turn N and then finalises visible text on turn N+1.
    public var scriptedToolCallsPerTurn: [[ToolCall]] = []

    /// Tokens the backend will yield on turn N, when
    /// ``scriptedToolCallsPerTurn`` is driving the conversation. Entries are
    /// popped in step with the per-turn tool-call queue. Empty queue falls
    /// back to the flat ``tokensToYield`` property.
    public var tokensToYieldPerTurn: [[String]] = []

    // Track calls
    public var loadModelCallCount = 0
    public var generateCallCount = 0
    public var stopCallCount = 0
    public var unloadCallCount = 0
    public var resetConversationCallCount = 0

    /// Records whether `loadModel` was called on the main thread.
    /// `nil` until `loadModel` has been called at least once.
    public var loadModelCalledOnMainThread: Bool?

    // Capture last generate arguments
    public var lastPrompt: String?
    public var lastSystemPrompt: String?
    public var lastConfig: GenerationConfig?

    /// Stored so stopGeneration() can terminate the in-flight stream.
    ///
    /// Protected by `continuationLock` — written from the generation Task
    /// (on an arbitrary thread) and read/cleared from stopGeneration() which
    /// can be called concurrently from any thread. Without serialization this
    /// is a data race under TSan.
    private var activeContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
    private let continuationLock = NSLock()

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

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        loadModelCallCount += 1
        loadModelCalledOnMainThread = pthread_main_np() != 0
        if let error = shouldThrowOnLoad { throw error }
        isModelLoaded = true
    }

    public func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        generateCallCount += 1
        lastPrompt = prompt
        lastSystemPrompt = systemPrompt
        lastConfig = config
        if let error = shouldThrowOnGenerate { throw error }
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }

        isGenerating = true
        // Per-turn scripting takes precedence when configured. Pop from the
        // front so successive generate() calls drive different turns.
        let toolCalls: [ToolCall]
        let tokens: [String]
        if !scriptedToolCallsPerTurn.isEmpty {
            toolCalls = scriptedToolCallsPerTurn.removeFirst()
            if !tokensToYieldPerTurn.isEmpty {
                tokens = tokensToYieldPerTurn.removeFirst()
            } else {
                tokens = tokensToYield
            }
        } else {
            toolCalls = scriptedToolCalls
            tokens = tokensToYield
        }

        let thinkingTokens = thinkingTokensToYield

        let stream = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            continuationLock.lock()
            self.activeContinuation = continuation
            continuationLock.unlock()
            continuation.onTermination = { @Sendable [self] _ in
                self.continuationLock.lock()
                self.activeContinuation = nil
                self.continuationLock.unlock()
            }
            Task {
                for t in thinkingTokens {
                    if Task.isCancelled { break }
                    continuation.yield(.thinkingToken(t))
                }
                if !thinkingTokens.isEmpty && !Task.isCancelled {
                    continuation.yield(.thinkingComplete)
                }
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                if !Task.isCancelled {
                    for call in toolCalls {
                        if Task.isCancelled { break }
                        continuation.yield(.toolCall(call))
                    }
                }
                self.isGenerating = false
                if let streamError = self.shouldThrowInsideStream, !Task.isCancelled {
                    continuation.finish(throwing: streamError)
                    return
                }
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    public func stopGeneration() {
        // `stopCallCount` is read-modify-written under the same lock that
        // guards `activeContinuation`. Without synchronization, concurrent
        // stops race on the increment and tests counting fan-out invocations
        // observe lost updates (see StopGenerationConcurrencyTests #418).
        continuationLock.lock()
        stopCallCount += 1
        isGenerating = false
        let cont = activeContinuation
        activeContinuation = nil
        continuationLock.unlock()
        cont?.finish()
    }

    public func unloadModel() {
        unloadCallCount += 1
        isModelLoaded = false
        isGenerating = false
    }

    public func resetConversation() {
        resetConversationCallCount += 1
    }

    // MARK: - ConversationHistoryReceiver

    public var lastReceivedHistory: [(role: String, content: String)]?

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        lastReceivedHistory = messages
    }
}

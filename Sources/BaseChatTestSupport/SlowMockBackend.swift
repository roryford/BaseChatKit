import Foundation
import BaseChatCore

/// A mock backend that yields tokens with configurable delays, enabling
/// cancellation to be tested mid-stream.
///
/// Shared across test targets via BaseChatTestSupport.
public final class SlowMockBackend: InferenceBackend, @unchecked Sendable {
    private let stateLock = NSLock()
    private var _isModelLoaded = true
    private var _isGenerating = false
    private var _tokensToYield: [String] = []
    private var _delayPerToken: Duration = .milliseconds(50)
    private var generationTask: Task<Void, Never>?

    public var isModelLoaded: Bool {
        get { withStateLock { _isModelLoaded } }
        set { withStateLock { _isModelLoaded = newValue } }
    }

    public var isGenerating: Bool {
        get { withStateLock { _isGenerating } }
        set { withStateLock { _isGenerating = newValue } }
    }

    public let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    public var tokensToYield: [String] {
        get { withStateLock { _tokensToYield } }
        set { withStateLock { _tokensToYield = newValue } }
    }

    public var delayPerToken: Duration {
        get { withStateLock { _delayPerToken } }
        set { withStateLock { _delayPerToken = newValue } }
    }

    public init() {}

    deinit {
        cancelGeneration(markModelUnloaded: false)
    }

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
        withStateLock { _isModelLoaded = true }
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let (tokens, delay) = withStateLock {
            _isGenerating = true
            return (_tokensToYield, _delayPerToken)
        }

        return AsyncThrowingStream { [weak self] continuation in
            let task = Task { [weak self] in
                defer {
                    self?.finishGeneration()
                    continuation.finish()
                }

                for token in tokens {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
            self?.setGenerationTask(task)
        }
    }

    public func stopGeneration() {
        cancelGeneration(markModelUnloaded: false)
    }

    public func unloadModel() {
        cancelGeneration(markModelUnloaded: true)
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func setGenerationTask(_ task: Task<Void, Never>) {
        withStateLock {
            generationTask = task
        }
    }

    private func finishGeneration() {
        withStateLock {
            _isGenerating = false
            generationTask = nil
        }
    }

    private func cancelGeneration(markModelUnloaded: Bool) {
        let task = withStateLock {
            if markModelUnloaded {
                _isModelLoaded = false
            }
            _isGenerating = false
            let task = generationTask
            generationTask = nil
            return task
        }
        task?.cancel()
    }
}

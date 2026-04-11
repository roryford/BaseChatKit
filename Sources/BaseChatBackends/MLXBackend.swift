#if MLX
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import os
import BaseChatInference

/// MLX Swift inference backend for safetensors/MLX-format models.
///
/// Uses the high-level `MLXLLM` API from `mlx-swift-lm`. Models are loaded
/// from local directories containing `config.json` + `.safetensors` weights,
/// or downloaded from HuggingFace by model ID.
///
/// Requires real Apple Silicon hardware — does not work in iOS Simulator.
public final class MLXBackend: InferenceBackend, @unchecked Sendable {

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )

    // MARK: - State

    private var _isModelLoaded = false
    private var _isGenerating = false

    public private(set) var isModelLoaded: Bool {
        get { withStateLock { _isModelLoaded } }
        set { withStateLock { _isModelLoaded = newValue } }
    }

    public private(set) var isGenerating: Bool {
        get { withStateLock { _isGenerating } }
        set { withStateLock { _isGenerating = newValue } }
    }

    // MARK: - Locking

    private let stateLock = NSLock()

    @discardableResult
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - Capabilities

    public let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 8192,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: false,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: true,
        memoryStrategy: .resident,
        maxOutputTokens: 4096,
        supportsStreaming: true,
        isRemote: false
    )

    // MARK: - Private

    /// Access only under `stateLock`.
    private var _modelContainer: (any MLXModelContainerProtocol)?
    /// Access only under `stateLock`.
    private var _generationTask: Task<Void, Never>?

    // MARK: - Configuration

    /// Policy controlling MLX's GPU buffer cache size. See `MLXCachePolicy`.
    /// Defaults to `.auto`, which picks a sensible value based on device RAM.
    public let cachePolicy: MLXCachePolicy

    // MARK: - Init

    public init(cachePolicy: MLXCachePolicy = .auto) {
        self.cachePolicy = cachePolicy
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        unloadModel()

        do {
            // Load from a local directory containing config.json + .safetensors.
            // loadModelContainer(from:using:) is a free function from MLXLMCommon.
            // #huggingFaceTokenizerLoader() (from MLXHuggingFace) adapts swift-transformers'
            // AutoTokenizer to the TokenizerLoader protocol required by the new API.
            let container: ModelContainer = try await loadModelContainer(
                from: url,
                using: #huggingFaceTokenizerLoader()
            )
            withStateLock {
                _modelContainer = container
            }
            // Apply the cache policy after loadModelContainer succeeds. Doing
            // this *after* the load (rather than before) keeps it inside the
            // implicit "MLX runtime is initialized" window — touching MLX's
            // Memory namespace before the runtime is up trips a metallib
            // load error in environments without Xcode-compiled shaders
            // (e.g. `swift test`). The cost is that the load itself runs
            // under whatever cacheLimit was previously in effect — usually
            // mlx-swift's own default on a fresh process, which is fine.
            let cacheBytes = cachePolicy.resolvedBytes()
            Memory.cacheLimit = cacheBytes
            Self.logger.info("MLX cache limit set to \(cacheBytes / (1024 * 1024)) MB (policy: \(String(describing: self.cachePolicy)))")
            isModelLoaded = true
            Self.logger.info("MLX backend loaded model from \(url.lastPathComponent)")
        } catch {
            Self.logger.error("MLX model load failed: \(error)")
            throw InferenceError.modelLoadFailed(underlying: error)
        }
    }

    // MARK: - Generation

    /// Generates a token stream from the loaded MLX model.
    ///
    /// - Important: Generation is dispatched to `@MainActor` because `ModelContainer.generate()`
    ///   in `mlx-swift-lm` must be called on the main thread (the MLX GPU scheduler is not
    ///   thread-safe). This means long responses will occupy the main event loop. The effect
    ///   is mitigated by the relatively short context windows used for on-device inference.
    ///   If a future version of `mlx-swift-lm` supports a background-thread generate API,
    ///   remove the `@MainActor` annotation from the inner `Task`.
    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let modelContainer: any MLXModelContainerProtocol = try withStateLock {
            guard _isModelLoaded, let container = _modelContainer else {
                throw InferenceError.inferenceFailure("No model loaded")
            }
            guard !_isGenerating else {
                throw InferenceError.alreadyGenerating
            }
            _isGenerating = true
            return container
        }
        Self.logger.debug("MLX generate started")

        let generateConfig = GenerateParameters(
            temperature: config.temperature,
            topP: config.topP,
            repetitionPenalty: config.repeatPenalty
        )

        // Build messages in chat format.
        let messages: [[String: String]] = {
            var msgs: [[String: String]] = []
            if let systemPrompt, !systemPrompt.isEmpty {
                msgs.append(["role": "system", "content": systemPrompt])
            }
            msgs.append(["role": "user", "content": prompt])
            return msgs
        }()

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let generationStream = GenerationStream(stream)

        let task = Task { @MainActor [weak self, generationStream] in
            defer {
                self?.withStateLock { self?._isGenerating = false }
                Self.logger.debug("MLX generate finished")
            }

            do {
                let outputLimit = config.maxOutputTokens
                var outputTokenCount = 0
                var isFirstToken = true
                let mlxStream = try await modelContainer.generate(
                    messages: messages,
                    parameters: generateConfig
                )
                for await generation in mlxStream {
                    if Task.isCancelled { break }
                    if let text = generation.chunk {
                        if isFirstToken {
                            await MainActor.run { generationStream.setPhase(.streaming) }
                            isFirstToken = false
                        }
                        continuation.yield(.token(text))
                        // Each chunk from MLX corresponds to one token.
                        if let limit = outputLimit {
                            outputTokenCount += 1
                            if outputTokenCount >= limit { break }
                        }
                    }
                }
                await MainActor.run { generationStream.setPhase(.done) }
            } catch {
                if !Task.isCancelled {
                    Self.logger.error("MLX generation error: \(error)")
                    await MainActor.run { generationStream.setPhase(.failed(error.localizedDescription)) }
                    continuation.finish(throwing: error)
                    return
                }
                await MainActor.run { generationStream.setPhase(.done) }
            }
            continuation.finish()
        }

        withStateLock { self._generationTask = task }

        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }

        return generationStream
    }

    // MARK: - Testing

    /// Injects a mock container so unit tests can exercise the generation path
    /// without loading real model weights. Call this before `generate()`.
    ///
    /// Not part of the public API — visible to `BaseChatBackendsTests` via `@testable import`.
    func _inject(_ container: any MLXModelContainerProtocol) {
        withStateLock {
            _modelContainer = container
            _isModelLoaded = true
        }
    }

    // MARK: - Control

    public func stopGeneration() {
        withStateLock {
            _generationTask?.cancel()
            _generationTask = nil
        }
    }

    public func unloadModel() {
        stopGeneration()
        // Capture whether we actually had a loaded container *before* clearing
        // state. We use this to decide whether to call Memory.clearCache()
        // below — touching MLX's Memory namespace requires the metallib to be
        // resident in the process, which is only true after a successful
        // model load. Calling clearCache() on a never-loaded backend (e.g.
        // from BackendContractChecks.assertAllInvariants) trips a "Failed to
        // load default metallib" error under `swift test`, because the
        // metallib is only compiled by Xcode and isn't present in the SwiftPM
        // build output.
        let hadContainer: Bool = withStateLock {
            let had = _modelContainer != nil
            _modelContainer = nil
            _isModelLoaded = false
            _isGenerating = false
            return had
        }
        if hadContainer {
            Memory.clearCache()
        }
        Self.logger.info("MLX backend unloaded")
    }
}
#endif

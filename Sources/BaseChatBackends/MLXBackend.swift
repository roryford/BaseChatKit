#if MLX
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os
import BaseChatCore

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

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

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

    private var modelContainer: (any MLXModelContainerProtocol)?
    private var generationTask: Task<Void, Never>?

    // MARK: - Init

    public init() {}

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        unloadModel()

        do {
            // Load from a local directory containing config.json + .safetensors.
            // loadModelContainer is a free function from MLXLMCommon.
            let container: ModelContainer = try await loadModelContainer(
                directory: url
            ) { _ in
                // Loading progress — useful for large models.
                // For local models this completes quickly.
            }
            modelContainer = container
            Memory.cacheLimit = 20 * 1024 * 1024
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
        guard isModelLoaded, let modelContainer else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        guard !isGenerating else {
            throw InferenceError.alreadyGenerating
        }

        isGenerating = true
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
                self?.isGenerating = false
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

        self.generationTask = task

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
        modelContainer = container
        isModelLoaded = true
    }

    // MARK: - Control

    public func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

    public func unloadModel() {
        stopGeneration()
        modelContainer = nil
        Memory.clearCache()
        isModelLoaded = false
        isGenerating = false
        Self.logger.info("MLX backend unloaded")
    }
}
#endif

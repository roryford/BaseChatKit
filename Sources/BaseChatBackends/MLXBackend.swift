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
        supportsSystemPrompt: true
    )

    // MARK: - Private

    private var modelContainer: ModelContainer?
    private var generationTask: Task<Void, Never>?

    // MARK: - Init

    public init() {}

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        unloadModel()

        do {
            // Load from a local directory containing config.json + .safetensors.
            // loadModelContainer is a free function from MLXLMCommon.
            let container = try await loadModelContainer(
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

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
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

        return AsyncThrowingStream { [weak self] continuation in
            let task = Task { @MainActor in
                defer {
                    self?.isGenerating = false
                    Self.logger.debug("MLX generate finished")
                }

                do {
                    let input = try await modelContainer.perform { context in
                        try await context.processor.prepare(input: .init(messages: messages))
                    }
                    let stream = try await modelContainer.generate(
                        input: input,
                        parameters: generateConfig
                    )
                    for await generation in stream {
                        if Task.isCancelled { break }
                        if let text = generation.chunk {
                            continuation.yield(text)
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        Self.logger.error("MLX generation error: \(error)")
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }

            self?.generationTask = task

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
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

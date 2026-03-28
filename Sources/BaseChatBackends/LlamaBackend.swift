import Foundation
import LlamaSwift
import os
import BaseChatCore

/// llama.cpp inference backend for GGUF-format models.
///
/// Uses the llama.cpp C API via `mattt/llama.swift` (pre-built xcframework).
/// Models are loaded from local `.gguf` files. Prompt formatting is handled
/// externally by `InferenceService` using the detected `PromptTemplate`.
public final class LlamaBackend: InferenceBackend {

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
        maxContextTokens: 4096,
        requiresPromptTemplate: true,
        supportsSystemPrompt: true
    )

    // MARK: - Private

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var generationTask: Task<Void, Never>?
    private var cancelled = false

    // MARK: - Init / Deinit

    public init() {
        llama_backend_init()
    }

    deinit {
        unloadModel()
        llama_backend_free()
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        unloadModel()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99  // Offload all layers to Metal

        guard let loadedModel = llama_model_load_from_file(url.path, modelParams) else {
            throw InferenceError.modelLoadFailed(underlying: NSError(
                domain: "LlamaBackend",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load GGUF model from \(url.lastPathComponent)"]
            ))
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextSize)
        ctxParams.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        ctxParams.n_threads_batch = ctxParams.n_threads

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw InferenceError.modelLoadFailed(underlying: NSError(
                domain: "LlamaBackend",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create llama context"]
            ))
        }

        self.model = loadedModel
        self.context = ctx
        self.vocab = llama_model_get_vocab(loadedModel)
        self.isModelLoaded = true

        Self.logger.info("Llama backend loaded \(url.lastPathComponent) with context \(contextSize)")
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded, let context, let vocab, model != nil else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        guard !isGenerating else {
            throw InferenceError.alreadyGenerating
        }

        isGenerating = true
        cancelled = false
        Self.logger.debug("Llama generate started")

        // Tokenize prompt
        let tokens = tokenize(prompt, addBos: true)
        guard !tokens.isEmpty else {
            isGenerating = false
            throw InferenceError.inferenceFailure("Failed to tokenize prompt")
        }

        let maxTokens = Int(config.maxTokens)

        return AsyncThrowingStream { [weak self] continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                defer {
                    self.isGenerating = false
                    Self.logger.debug("Llama generate finished")
                }

                // Set up sampler chain
                let sparams = llama_sampler_chain_default_params()
                guard let sampler = llama_sampler_chain_init(sparams) else {
                    continuation.finish(throwing: InferenceError.inferenceFailure("Failed to create sampler"))
                    return
                }
                defer { llama_sampler_free(sampler) }

                if config.repeatPenalty != 1.0 {
                    llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
                        64,                    // last_n tokens to penalize
                        config.repeatPenalty,  // repeat penalty
                        0.0,                   // frequency penalty
                        0.0                    // presence penalty
                    ))
                }
                if config.topP < 1.0 {
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(config.topP, 1))
                }
                llama_sampler_chain_add(sampler, llama_sampler_init_temp(config.temperature))
                llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

                // Create batch and process prompt
                var batch = llama_batch_init(Int32(tokens.count), 0, 1)
                defer { llama_batch_free(batch) }

                for (i, token) in tokens.enumerated() {
                    batch.token[i] = token
                    batch.pos[i] = Int32(i)
                    batch.n_seq_id[i] = 1
                    batch.seq_id[i]?[0] = 0
                    batch.logits[i] = (i == tokens.count - 1) ? 1 : 0
                }
                batch.n_tokens = Int32(tokens.count)

                if llama_decode(context, batch) != 0 {
                    continuation.finish(throwing: InferenceError.inferenceFailure("Failed to decode prompt"))
                    return
                }

                // Generation loop
                var nCur = Int(batch.n_tokens)
                var invalidUTF8: [CChar] = []

                for _ in 0..<maxTokens {
                    if Task.isCancelled || self.cancelled { break }

                    let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)

                    if llama_vocab_is_eog(vocab, token) { break }

                    // Decode token to text
                    if let text = self.tokenToString(token, invalidUTF8Buffer: &invalidUTF8) {
                        continuation.yield(text)
                    }

                    // Prepare next batch
                    batch.n_tokens = 0
                    batch.token[0] = token
                    batch.pos[0] = Int32(nCur)
                    batch.n_seq_id[0] = 1
                    batch.seq_id[0]?[0] = 0
                    batch.logits[0] = 1
                    batch.n_tokens = 1
                    nCur += 1

                    if llama_decode(context, batch) != 0 {
                        continuation.finish(throwing: InferenceError.inferenceFailure("Decode failed during generation"))
                        return
                    }
                }

                // Clear KV cache for next generation
                let memory = llama_get_memory(context)
                llama_memory_clear(memory, false)

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
        cancelled = true
        generationTask?.cancel()
        generationTask = nil
    }

    public func unloadModel() {
        stopGeneration()
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
        isModelLoaded = false
        isGenerating = false
        Self.logger.info("Llama backend unloaded")
    }

    // MARK: - Tokenization Helpers

    private func tokenize(_ text: String, addBos: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8 = text.utf8CString
        let maxTokens = Int32(utf8.count) + (addBos ? 1 : 0)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
        let count = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, maxTokens, addBos, false)
        guard count >= 0 else { return [] }
        return Array(tokens.prefix(Int(count)))
    }

    /// Converts a token to a string, handling multi-byte UTF-8 sequences that
    /// may span token boundaries.
    private func tokenToString(_ token: llama_token, invalidUTF8Buffer: inout [CChar]) -> String? {
        guard let vocab else { return nil }
        var buf = [CChar](repeating: 0, count: 32)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)

        if n < 0 {
            // Buffer too small — retry with correct size
            buf = [CChar](repeating: 0, count: Int(-n))
            let n2 = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            guard n2 >= 0 else { return nil }
            invalidUTF8Buffer.append(contentsOf: buf.prefix(Int(n2)))
        } else {
            invalidUTF8Buffer.append(contentsOf: buf.prefix(Int(n)))
        }

        // Try to form a valid UTF-8 string
        invalidUTF8Buffer.append(0) // null-terminate
        if let str = String(validatingUTF8: invalidUTF8Buffer) {
            invalidUTF8Buffer.removeAll()
            return str.isEmpty ? nil : str
        }
        invalidUTF8Buffer.removeLast() // remove null terminator, keep accumulating
        return nil
    }
}

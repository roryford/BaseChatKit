#if Llama
import Foundation
import LlamaSwift
import os
import BaseChatCore

/// llama.cpp inference backend for GGUF-format models.
///
/// Uses the llama.cpp C API via `mattt/llama.swift` (pre-built xcframework).
/// Models are loaded from local `.gguf` files. Prompt formatting is handled
/// externally by `InferenceService` using the detected `PromptTemplate`.
public final class LlamaBackend: InferenceBackend, @unchecked Sendable {

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )

    // MARK: - State

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    // MARK: - Locking

    /// Guards mutable runtime state and pending async lifecycle work.
    /// These values are read from @MainActor callers and written from detached
    /// tasks that may outlive the initiating method call.
    private let stateLock = NSLock()

    /// Serializes concurrent `initializeModel` C-level calls.
    ///
    /// `llama_model_load_from_file` and `llama_free` are not safe to call concurrently.
    /// This lock ensures at most one detached load task is inside the C API at a time.
    /// Blocking is acceptable here because the lock is only held inside a detached task.
    private let loadSerializationLock = NSLock()

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Capabilities

    private var _effectiveContextSize: Int32 = 4096

    public var capabilities: BackendCapabilities {
        let ctxSize = withStateLock { _effectiveContextSize }
        return BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: ctxSize,
            requiresPromptTemplate: true,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .explicit,
            supportsTokenCounting: true,
            memoryStrategy: .mappable,
            maxOutputTokens: 4096,
            supportsStreaming: true,
            isRemote: false
        )
    }

    // MARK: - Private

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var generationTask: Task<Void, Never>?
    private var cancelled = false
    private var cleanupTask: Task<Void, Never>?
    private var nextLoadToken: UInt64 = 0
    private var activeLoadToken: UInt64 = 0

    // MARK: - Global Backend Lifecycle

    /// Guards `llama_backend_init/free` which are global and must only be
    /// called once, not per-instance.
    /// NSLock is intentional here: init/deinit are synchronous, so actor
    /// isolation would require fire-and-forget Tasks with no ordering guarantee.
    private static var backendRefCount = 0
    private static let backendLock = NSLock()

    private static func retainBackend() {
        backendLock.lock()
        defer { backendLock.unlock() }
        if backendRefCount == 0 {
            llama_backend_init()
        }
        backendRefCount += 1
    }

    private static func releaseBackend() {
        backendLock.lock()
        defer { backendLock.unlock() }
        backendRefCount -= 1
        if backendRefCount == 0 {
            llama_backend_free()
        }
    }

    // MARK: - Init / Deinit

    public init() {
        Self.retainBackend()
    }

    deinit {
        unloadModel()
        Self.releaseBackend()
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        unloadModel()
        await waitForPendingCleanup()

        let loadToken = withStateLock {
            nextLoadToken &+= 1
            activeLoadToken = nextLoadToken
            return activeLoadToken
        }

        let loadedResources = try await Task.detached(priority: .userInitiated) { [self] in
            self.loadSerializationLock.lock()
            defer { self.loadSerializationLock.unlock() }
            return try Self.initializeModel(at: url, requestedContextSize: contextSize)
        }.value

        let didCommit = withStateLock {
            guard activeLoadToken == loadToken else {
                return false
            }
            self.model = loadedResources.model
            self.context = loadedResources.context
            self.vocab = loadedResources.vocab
            self.isModelLoaded = true
            self._effectiveContextSize = loadedResources.effectiveContextSize
            return true
        }

        guard didCommit else {
            llama_free(loadedResources.context)
            llama_model_free(loadedResources.model)
            throw CancellationError()
        }

        Self.logger.info("Llama backend loaded \(url.lastPathComponent) with context \(loadedResources.effectiveContextSize)")
    }

    private struct LoadedResources {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer?
        let effectiveContextSize: Int32
    }

    private static func initializeModel(
        at url: URL,
        requestedContextSize: Int32
    ) throws -> LoadedResources {
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0   // Metal not reliable in simulator
        #else
        modelParams.n_gpu_layers = 99  // Offload all layers to Metal
        #endif

        guard let loadedModel = llama_model_load_from_file(url.path, modelParams) else {
            throw InferenceError.modelLoadFailed(underlying: NSError(
                domain: "LlamaBackend",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load GGUF model from \(url.lastPathComponent)"]
            ))
        }

        var ctxParams = llama_context_default_params()
        // Respect the model's actual training context length — hard-capping at 8192
        // prevents long-context models (32K–128K) from using their full window.
        let trainedContextLength = Int32(llama_model_n_ctx_train(loadedModel))
        // Device-safe cap: 1 token ≈ 8 KB of KV cache (2 KB per layer element × 4 bytes);
        // physicalMemory / 8 192 gives the token count that would exhaust all RAM,
        // clamped to 128 000 as an absolute ceiling.
        let availableRAM = Int64(ProcessInfo.processInfo.physicalMemory)
        let ramSafeCap = Int32(min(Int64(128_000), availableRAM / (2 * 1024 * 4)))
        let effectiveContextSize = min(requestedContextSize, trainedContextLength, ramSafeCap)
        ctxParams.n_ctx = UInt32(effectiveContextSize)
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

        return LoadedResources(
            model: loadedModel,
            context: ctx,
            vocab: llama_model_get_vocab(loadedModel),
            effectiveContextSize: effectiveContextSize
        )
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard isModelLoaded, let context, let vocab, model != nil else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        guard !withStateLock({ isGenerating }) else {
            throw InferenceError.alreadyGenerating
        }

        withStateLock {
            isGenerating = true
            cancelled = false
        }
        Self.logger.debug("Llama generate started")

        // Tokenize prompt
        let tokens = tokenize(prompt, addBos: true)
        guard !tokens.isEmpty else {
            withStateLock { isGenerating = false }
            throw InferenceError.inferenceFailure("Failed to tokenize prompt")
        }

        let maxTokens = config.maxOutputTokens ?? Int(config.maxTokens)

        let stream = AsyncThrowingStream { [weak self] continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                defer {
                    self.withStateLock { self.isGenerating = false }
                    Self.logger.debug("Llama generate finished")
                }

                // Set up sampler chain
                let sparams = llama_sampler_chain_default_params()
                guard let sampler = llama_sampler_chain_init(sparams) else {
                    continuation.finish(throwing: InferenceError.inferenceFailure("Failed to create sampler"))
                    return
                }
                defer { llama_sampler_free(sampler) }

                // Sampler chain order matters: penalties → top_k → top_p → temp → dist
                if config.repeatPenalty > 1.0 {
                    llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
                        64,                    // last_n tokens to penalize
                        config.repeatPenalty,  // repeat penalty
                        0.0,                   // frequency penalty
                        0.0                    // presence penalty
                    ))
                }
                llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
                if config.topP < 1.0 {
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(config.topP, 1))
                }
                llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
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
                    if Task.isCancelled || self.withStateLock({ self.cancelled }) { break }

                    let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)

                    if llama_vocab_is_eog(vocab, token) { break }

                    // Decode token to text
                    if let text = self.tokenToString(token, invalidUTF8Buffer: &invalidUTF8) {
                        continuation.yield(.token(text))
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

                    if Task.isCancelled || self.withStateLock({ self.cancelled }) { break }

                    if llama_decode(context, batch) != 0 {
                        continuation.finish(throwing: InferenceError.inferenceFailure("Decode failed during generation"))
                        return
                    }
                }

                // Clear KV cache for next generation (skip if cancelled/unloaded)
                if !self.withStateLock({ self.cancelled }), let memory = llama_get_memory(context) {
                    llama_memory_clear(memory, false)
                }

                continuation.finish()
            }

            self?.generationTask = task

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
        return GenerationStream(stream)
    }

    // MARK: - Control

    public func stopGeneration() {
        withStateLock { cancelled = true }
        generationTask?.cancel()
        generationTask = nil
    }

    public func unloadModel() {
        let state = withStateLock {
            cancelled = true
            nextLoadToken &+= 1
            activeLoadToken = nextLoadToken

            let previousCleanup = cleanupTask
            cleanupTask = nil
            let capturedTask = generationTask
            let capturedContext = context
            let capturedModel = model

            // Clear state immediately so callers see the backend as unloaded
            // without waiting for C memory deallocation.
            generationTask = nil
            context = nil
            model = nil
            vocab = nil
            isModelLoaded = false
            isGenerating = false
            return (
                previousCleanup: previousCleanup,
                capturedTask: capturedTask,
                capturedContext: capturedContext,
                capturedModel: capturedModel
            )
        }
        state.capturedTask?.cancel()

        Self.logger.info("Llama backend unloaded")

        guard state.capturedTask != nil || state.capturedContext != nil || state.capturedModel != nil else {
            withStateLock {
                cleanupTask = state.previousCleanup
            }
            return
        }

        Self.retainBackend()

        // Defer llama_free off the calling thread — InferenceService is @MainActor,
        // so blocking here would freeze the UI for the duration of the spin-wait.
        // We await the generation task to ensure the C loop has stopped before
        // touching the pointers, preventing a use-after-free crash.
        let cleanupTask = Task.detached(priority: .utility) {
            await state.previousCleanup?.value
            await state.capturedTask?.value
            if let ctx = state.capturedContext { llama_free(ctx) }
            if let mdl = state.capturedModel { llama_model_free(mdl) }
            Self.releaseBackend()
        }
        withStateLock {
            self.cleanupTask = cleanupTask
        }
    }

    // MARK: - Tokenization Helpers

    private func waitForPendingCleanup() async {
        let task = withStateLock {
            let task = cleanupTask
            cleanupTask = nil
            return task
        }
        await task?.value
    }

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

// MARK: - TokenizerVendor

extension LlamaBackend: TokenizerVendor, TokenizerProvider {
    /// Vends `self` as the synchronous tokenizer.
    ///
    /// `llama_tokenize` is a pure vocabulary lookup — safe to call from any thread
    /// while the model is loaded. `LlamaBackend` is already `@unchecked Sendable`.
    public var tokenizer: any TokenizerProvider { self }

    /// Returns the number of tokens in `text` using the loaded llama.cpp vocabulary.
    ///
    /// Falls back to the 4-chars-per-token heuristic if no vocabulary is loaded.
    /// Callers should prefer accessing this through `InferenceService.tokenizer`.
    public func tokenCount(_ text: String) -> Int {
        let tokens = tokenize(text, addBos: false)
        return tokens.isEmpty ? max(1, text.count / 4) : tokens.count
    }
}
#endif

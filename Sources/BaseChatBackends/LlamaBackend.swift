#if Llama
import Foundation
import LlamaSwift
import os
import Synchronization
import BaseChatInference

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
    /// Cancellation flag shared between the decode loop (background task) and
    /// `stopGeneration()` / `unloadModel()` (any thread/actor).
    ///
    /// `Atomic<Bool>` (Swift 6 `Synchronization` stdlib) makes every read and
    /// write sequentially consistent without requiring a lock, eliminating the
    /// data race that existed when a plain `Bool` was written from the main actor
    /// and read on a detached background task. This is also safe to write from
    /// a memory-pressure handler callback (#415) running on an arbitrary thread.
    private let cancelled = Atomic<Bool>(false)
    private var cleanupTask: Task<Void, Never>?
    private var nextLoadToken: UInt64 = 0
    private var activeLoadToken: UInt64 = 0

    /// Guarded by `stateLock`. Set by `setLoadProgressHandler(_:)` before each load.
    private var _loadProgressHandler: (@Sendable (Double) async -> Void)?

    /// Owns the serialized model-load path and the C-level parameter/progress-callback bridging.
    private let modelLoader = LlamaModelLoader()

    // MARK: - Memory Pressure

    /// Monitors OS-level memory pressure so the decode loop can be aborted before
    /// the OS revokes Metal buffers, which would cause llama_decode to dereference
    /// a freed pointer and crash with SIGSEGV / EXC_BAD_ACCESS. See issue #415.
    ///
    /// `LlamaBackend` owns this handler and registers its callback in `init`, so
    /// pressure events are handled here regardless of whether a `ChatViewModel` or
    /// any other higher-level observer is also listening.
    private let memoryPressure = MemoryPressureHandler()

    // MARK: - Init / Deinit

    public init() {
        LlamaBackendProcessLifecycle.retain()
        registerMemoryPressureCallback()
        memoryPressure.startMonitoring()
    }

    deinit {
        memoryPressure.removeCallback(for: self)
        memoryPressure.stopMonitoring()
        unloadModel()
        LlamaBackendProcessLifecycle.release()
    }

    // MARK: - Memory Pressure Wiring

    /// Registers the backend-level memory pressure callback.
    ///
    /// On `.warning`: calls `stopGeneration()` immediately so the decode loop exits
    /// cleanly before the OS escalates. `stopGeneration()` uses `Atomic<Bool>` and is
    /// safe to call from any thread (PR #456).
    ///
    /// On `.critical`: calls `stopGeneration()` AND schedules a `Task.detached` to call
    /// `unloadAndWait()`, releasing Metal buffers before the OS reclaims them forcibly.
    /// `Task.detached` is used explicitly so the task does not inherit any actor isolation
    /// from the GCD callback's execution context, and the GCD callback returns immediately.
    /// A weak capture prevents a retain cycle with the handler's closure storage.
    private func registerMemoryPressureCallback() {
        memoryPressure.addPressureCallback(for: self) { [weak self] level in
            guard let self else { return }
            switch level {
            case .warning:
                Self.logger.warning("Memory pressure: warning — stopping generation to prevent Metal buffer revocation (#415)")
                self.stopGeneration()
            case .critical:
                Self.logger.warning("Memory pressure: critical — stopping generation and scheduling model unload (#415)")
                self.stopGeneration()
                Task.detached { [weak self] in
                    await self?.unloadAndWait()
                }
            case .nominal:
                break
            }
        }
    }

    // MARK: - Model Lifecycle

    /// Plan-aware model load. The plan's ``ModelLoadPlan/effectiveContextSize``
    /// is authoritative — no clamping happens inside llama.cpp's initializer.
    ///
    /// - Precondition: `plan.verdict != .deny`. Callers must check the verdict
    ///   before invoking; the backend assumes the plan is allow/warn.
    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        assert(plan.verdict != .deny,
               "ModelLoadPlan was denied; callers must check verdict before invoking backend")

        unloadModel()
        await waitForPendingCleanup()

        let loadToken = withStateLock {
            nextLoadToken &+= 1
            activeLoadToken = nextLoadToken
            return activeLoadToken
        }

        // Snapshotting the handler here means calling setLoadProgressHandler(nil)
        // mid-load will not cancel in-flight Task callbacks already dispatched by
        // the C progress hook. Stale callbacks become no-ops at the consumer:
        // InferenceService.applyLoadProgress(_:for:) drops values whose request
        // token no longer matches the active loading phase.
        let capturedHandler = withStateLock { _loadProgressHandler }
        let effectiveContextSize = Int32(plan.effectiveContextSize)

        let loadedResources = try await Task.detached(priority: .userInitiated) { [modelLoader] in
            return try modelLoader.serializedModelLoad(at: url, effectiveContextSize: effectiveContextSize, progressHandler: capturedHandler)
        }.value

        let didCommit = withStateLock {
            guard activeLoadToken == loadToken else {
                return false
            }
            // steal() transfers ownership; unloadModel's explicit ordered cleanup takes over.
            self.model = loadedResources.model.steal()
            self.context = loadedResources.context.steal()
            self.vocab = loadedResources.vocab
            self.isModelLoaded = true
            self._effectiveContextSize = loadedResources.effectiveContextSize
            return true
        }

        guard didCommit else {
            // loadedResources goes out of scope here. steal() was never called, so
            // LlamaContextHandle/LlamaModelHandle deinits free the C memory automatically.
            throw CancellationError()
        }

        Self.logger.info("Llama backend loaded \(url.lastPathComponent) with context \(loadedResources.effectiveContextSize)")
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        // The Task body re-reads context under stateLock below to avoid the
        // use-after-free window between here and `self.generationTask = task`
        // install. We only need to verify model is loaded up front — the
        // captured pointers are accessed through the re-read, not these
        // outer locals.
        guard isModelLoaded, context != nil, vocab != nil, model != nil else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        guard !withStateLock({ isGenerating }) else {
            throw InferenceError.alreadyGenerating
        }

        // Tokenize up front (pure vocab lookup — doesn't touch context KV
        // state) so we can preflight prompt + output against the context
        // window before flipping `isGenerating`. If we failed this check
        // after the flip, callers who retry on `.contextExhausted` would see
        // an unnecessary `.alreadyGenerating` on the next call.
        let tokens = LlamaTokenization.tokenize(prompt, vocab: vocab, addBos: true)
        guard !tokens.isEmpty else {
            throw InferenceError.inferenceFailure("Failed to tokenize prompt")
        }

        let maxTokens = config.maxOutputTokens ?? 2048
        let contextSize = Int(withStateLock { _effectiveContextSize })
        guard tokens.count + maxTokens <= contextSize else {
            throw InferenceError.contextExhausted(
                promptTokens: tokens.count,
                maxOutputTokens: maxTokens,
                contextSize: contextSize
            )
        }

        // Reset the cancellation flag and flip isGenerating atomically under the
        // same lock that stopGeneration() holds when it touches generationTask.
        // Keeping both writes inside a single critical section means a concurrent
        // stopGeneration() call that races this startup cannot observe a window
        // where cancelled == false but isGenerating == false (not yet set), which
        // would let it skip the task cancel and leave the loop running uncancelled.
        withStateLock {
            cancelled.store(false, ordering: .sequentiallyConsistent)
            isGenerating = true
        }
        Self.logger.debug("Llama generate started")

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let generationStream = GenerationStream(stream)

        // Hold stateLock across Task creation AND generationTask assignment
        // (see install block below). The Task body's first action is a
        // stateLock re-read, which blocks until we release. That guarantees
        // the Task body cannot observe `self.generationTask == nil` when its
        // re-read runs — so unloadModel() always either sees the installed
        // task (and awaits it) or runs entirely before the task's re-read
        // (and nils `self.context`, causing the task to bail).
        stateLock.lock()
        let task = Task { [weak self, generationStream] in
            guard let self else {
                continuation.finish()
                return
            }

            defer {
                self.withStateLock { self.isGenerating = false }
                Self.logger.debug("Llama generate finished")
            }

            // Re-acquire context and vocab under stateLock so we serialize
            // with unloadModel(). The parent installs `generationTask = task`
            // under stateLock below before releasing; that guarantees either:
            //   (a) unloadModel() ran first → `self.context` is nil → we bail
            //       cleanly without touching any freed pointer, or
            //   (b) the parent installed generationTask first → unloadModel()
            //       now observes the task and awaits it before calling
            //       llama_free / llama_model_free on the captured pointers.
            // Performing all context-touching work (KV clear, decode, sample)
            // inside this task keeps it under the lifecycle that
            // unloadModel() already knows how to wait for.
            let pointers = self.withStateLock { () -> (OpaquePointer, OpaquePointer)? in
                guard let ctx = self.context, let voc = self.vocab else { return nil }
                return (ctx, voc)
            }
            guard let (context, vocab) = pointers else {
                continuation.finish()
                return
            }

            // `n_batch` caps how many tokens can flow through a single
            // `llama_decode` call. llama.cpp asserts
            // `GGML_ASSERT(n_tokens_all <= cparams.n_batch)` in
            // `llama-context.cpp`, so prompts longer than this must be decoded
            // in chunks. We never set `n_batch` on `ctxParams`, so it inherits
            // llama.cpp's default (2048 at the time of writing).
            let batchSize = max(1, Int(llama_n_batch(context)))

            // Clear KV cache at the start so state from any prior run (including
            // one terminated by stopGeneration) can't collide with this run's
            // positions.
            if let memory = llama_get_memory(context) {
                llama_memory_clear(memory, false)
            }

            // Set up sampler chain
            let sparams = llama_sampler_chain_default_params()
            guard let sampler = llama_sampler_chain_init(sparams) else {
                await MainActor.run { generationStream.setPhase(.failed("Failed to create sampler")) }
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

            // Process prompt in `n_batch`-sized chunks. A single `llama_decode`
            // call cannot exceed `n_batch` tokens, so we stride through the
            // prompt and decode each chunk separately. Only the last token of
            // the final chunk has `logits = 1` — that's the one we sample from
            // to kick off generation.
            var promptDecodeFailed = false
            var promptPos = 0
            while promptPos < tokens.count {
                if Task.isCancelled || self.cancelled.load(ordering: .sequentiallyConsistent) { break }

                let chunkSize = min(batchSize, tokens.count - promptPos)
                let isLastChunk = (promptPos + chunkSize) == tokens.count

                var promptBatch = llama_batch_init(Int32(chunkSize), 0, 1)
                for i in 0..<chunkSize {
                    promptBatch.token[i] = tokens[promptPos + i]
                    promptBatch.pos[i] = Int32(promptPos + i)
                    promptBatch.n_seq_id[i] = 1
                    promptBatch.seq_id[i]?[0] = 0
                    promptBatch.logits[i] = (isLastChunk && i == chunkSize - 1) ? 1 : 0
                }
                promptBatch.n_tokens = Int32(chunkSize)

                let decodeResult = llama_decode(context, promptBatch)
                llama_batch_free(promptBatch)

                if decodeResult != 0 {
                    promptDecodeFailed = true
                    break
                }

                promptPos += chunkSize
            }

            if promptDecodeFailed {
                await MainActor.run { generationStream.setPhase(.failed("Failed to decode prompt")) }
                continuation.finish(throwing: InferenceError.inferenceFailure("Failed to decode prompt"))
                return
            }

            // Honour cancellation that fired mid-prompt before entering the
            // generation loop.
            if Task.isCancelled || self.cancelled.load(ordering: .sequentiallyConsistent) {
                await MainActor.run { generationStream.setPhase(.done) }
                continuation.finish()
                return
            }

            // Generation loop uses a fresh 1-capacity batch — the prompt loop
            // allocated and freed a batch per chunk, so there's nothing to
            // reuse here.
            var genBatch = llama_batch_init(1, 0, 1)
            defer { llama_batch_free(genBatch) }

            // The chunked prompt loop placed tokens at positions
            // [0, tokens.count - 1]; the next decoded token goes at
            // `tokens.count`.
            var nCur = tokens.count
            var invalidUTF8: [CChar] = []
            var isFirstToken = true

            for iteration in 0..<maxTokens {
                if Task.isCancelled || self.cancelled.load(ordering: .sequentiallyConsistent) { break }

                // First iteration samples from the final prompt chunk's logits,
                // which llama.cpp exposes at index -1 ("last available").
                // Subsequent iterations sample from the 1-token gen batch
                // decoded at the end of the previous iteration, at index 0.
                let logitIndex: Int32 = iteration == 0 ? -1 : 0
                let token = llama_sampler_sample(sampler, context, logitIndex)

                if llama_vocab_is_eog(vocab, token) { break }

                // Decode token to text
                if let text = LlamaTokenization.tokenToString(token, vocab: vocab, invalidUTF8Buffer: &invalidUTF8) {
                    if isFirstToken {
                        await MainActor.run { generationStream.setPhase(.streaming) }
                        isFirstToken = false
                    }
                    continuation.yield(.token(text))
                }

                // Prepare next batch
                genBatch.n_tokens = 0
                genBatch.token[0] = token
                genBatch.pos[0] = Int32(nCur)
                genBatch.n_seq_id[0] = 1
                genBatch.seq_id[0]?[0] = 0
                genBatch.logits[0] = 1
                genBatch.n_tokens = 1
                nCur += 1

                if Task.isCancelled || self.cancelled.load(ordering: .sequentiallyConsistent) { break }

                if llama_decode(context, genBatch) != 0 {
                    await MainActor.run { generationStream.setPhase(.failed("Decode failed during generation")) }
                    continuation.finish(throwing: InferenceError.inferenceFailure("Decode failed during generation"))
                    return
                }
            }

            await MainActor.run { generationStream.setPhase(.done) }

            continuation.finish()
        }

        // Assignment and unlock complete the critical section opened above.
        // unloadModel() will now observe `generationTask` whenever it beats
        // the task body to the lock — or, if unloadModel() ran fully before
        // we acquired the lock, the task body's re-read will see nil context
        // and bail out without touching freed pointers.
        self.generationTask = task
        stateLock.unlock()

        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }

        return generationStream
    }

    // MARK: - Control

    public func stopGeneration() {
        // Set the atomic flag first so the decode loop can break on its very next
        // iteration check — even before the lock is acquired below.
        cancelled.store(true, ordering: .sequentiallyConsistent)
        // Capture and nil-out generationTask under stateLock. generationTask is
        // a mutable var guarded by stateLock everywhere else (generate() assigns
        // it under the lock, unloadModel() captures it under the lock). Accessing
        // it here without the lock would be a data race under TSan.
        let taskToCancel = withStateLock {
            let t = generationTask
            generationTask = nil
            return t
        }
        taskToCancel?.cancel()
    }

    public func unloadModel() {
        // Signal the decode loop to stop before acquiring stateLock. The atomic
        // write is visible to the background task immediately, so the loop can
        // break on its next iteration check without waiting for the lock.
        cancelled.store(true, ordering: .sequentiallyConsistent)
        stateLock.lock()
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
        stateLock.unlock()

        capturedTask?.cancel()

        Self.logger.info("Llama backend unloaded")

        guard capturedTask != nil || capturedContext != nil || capturedModel != nil else {
            withStateLock {
                cleanupTask = previousCleanup
            }
            return
        }

        LlamaBackendProcessLifecycle.retain()

        // Defer llama_free off the calling thread — InferenceService is @MainActor,
        // so blocking here would freeze the UI for the duration of the spin-wait.
        // We await the generation task to ensure the C loop has stopped before
        // touching the pointers, preventing a use-after-free crash.
        let newCleanupTask = Task.detached(priority: .utility) {
            await previousCleanup?.value
            await capturedTask?.value
            if let ctx = capturedContext { llama_free(ctx) }
            if let mdl = capturedModel { llama_model_free(mdl) }
            LlamaBackendProcessLifecycle.release()
        }
        withStateLock {
            self.cleanupTask = newCleanupTask
        }
    }

    /// Schedules the same tear-down as `unloadModel()` and awaits completion of
    /// the detached cleanup task that frees the llama.cpp context and model.
    ///
    /// Use this before process exit or between back-to-back load cycles when
    /// deterministic teardown matters. Production code that drops the backend
    /// and immediately exits can keep calling fire-and-forget `unloadModel()` —
    /// but tests, programmatic reload loops, and anywhere Metal's `MTLDevice`
    /// deinit might race with `llama_free` should await this method instead.
    ///
    /// Without this, Metal's device tear-down can trip
    /// `ggml-metal-device.m:612: GGML_ASSERT([rsets->data count] == 0) failed`
    /// when the context still holds command-buffer resource sets at exit, which
    /// aborts the process with SIGABRT (swift-test exit code 1 even on a green
    /// suite). See issue #391.
    public func unloadAndWait() async {
        unloadModel()
        await waitForPendingCleanup()
    }

    // MARK: - Cleanup

    private func waitForPendingCleanup() async {
        let task = withStateLock {
            let task = cleanupTask
            cleanupTask = nil
            return task
        }
        await task?.value
    }
}

// MARK: - LoadProgressReporting

extension LlamaBackend: LoadProgressReporting {
    /// Installs a progress handler that receives fractional progress values in `[0.0, 1.0]`
    /// delivered by the llama.cpp `progress_callback` during `llama_model_load_from_file`.
    /// The handler fires from the loader thread via an unstructured Task.
    public func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?) {
        withStateLock { _loadProgressHandler = handler }
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
        let tokens = LlamaTokenization.tokenize(text, vocab: vocab, addBos: false)
        return tokens.isEmpty ? max(1, text.count / 4) : tokens.count
    }
}

// MARK: - TokenCountingBackend

extension LlamaBackend: TokenCountingBackend {
    /// Returns the exact token count for `text` using the loaded model's vocabulary.
    ///
    /// This calls `llama_tokenize` directly — a pure vocabulary lookup with no
    /// context state involved. Safe to call from any thread while the model is loaded.
    ///
    /// - Throws: ``InferenceError/inferenceFailure(_:)`` when the model is not loaded
    ///   or when `llama_tokenize` returns a negative value (buffer sizing failure).
    /// - Note: Call only after a successful `loadModel`. The model pointer is guarded
    ///   under `stateLock` to prevent a use-after-free race with `unloadModel()`.
    public func countTokens(_ text: String) throws -> Int {
        // Snapshot the vocab pointer under stateLock and use it directly for
        // llama_tokenize. Without this snapshot, calling tokenize() outside the
        // lock would re-read `self.vocab` and race with unloadModel() setting it
        // to nil and freeing the backing model — a use-after-free crash.
        // Holding the lock only for the snapshot (not the whole C call) keeps
        // `unloadModel()` responsive while still preventing the race.
        guard let currentVocab = withStateLock({ vocab }) else {
            throw InferenceError.inferenceFailure("countTokens called before model was loaded")
        }
        let utf8 = text.utf8CString
        let maxTokens = Int32(utf8.count) + 1  // +1 for BOS
        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
        let count = llama_tokenize(currentVocab, text, Int32(text.utf8.count), &tokens, maxTokens, true, false)
        guard count >= 0 || text.isEmpty else {
            throw InferenceError.inferenceFailure("countTokens: llama_tokenize failed for text of length \(text.utf8.count)")
        }
        return text.isEmpty ? 0 : Int(count)
    }
}
#endif

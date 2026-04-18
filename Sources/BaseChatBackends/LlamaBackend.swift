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

    // MARK: - Global Backend Lifecycle

    /// Guards `llama_backend_init/free` which are global and must only be
    /// called once, not per-instance.
    /// NSLock is intentional here: init/deinit are synchronous, so actor
    /// isolation would require fire-and-forget Tasks with no ordering guarantee.
    nonisolated(unsafe) private static var backendRefCount = 0
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

        let loadedResources = try await Task.detached(priority: .userInitiated) { [self] in
            return try self.serializedModelLoad(at: url, effectiveContextSize: effectiveContextSize, progressHandler: capturedHandler)
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

    /// Synchronous wrapper that holds `loadSerializationLock` while calling the
    /// C-level model init. Called from a detached task so the lock/unlock stays
    /// in a synchronous context (required by Swift 6.3 strict concurrency).
    private func serializedModelLoad(
        at url: URL,
        effectiveContextSize: Int32,
        progressHandler: (@Sendable (Double) async -> Void)?
    ) throws -> LoadedResources {
        loadSerializationLock.lock()
        defer { loadSerializationLock.unlock() }
        return try Self.initializeModel(at: url, effectiveContextSize: effectiveContextSize, progressHandler: progressHandler)
    }

    private struct LoadedResources: @unchecked Sendable {
        let model: LlamaModelHandle
        let context: LlamaContextHandle
        let effectiveContextSize: Int32
        var vocab: OpaquePointer? { context.vocabPtr }
    }

    // MARK: - RAII Pointer Wrappers
    //
    // These types own C pointers and free them on deinit, making error-path
    // cleanup in initializeModel automatic. On the successful load path,
    // steal() transfers ownership to the instance vars so that unloadModel's
    // explicit ordered cleanup (context before model, both before
    // llama_backend_free) is unaffected.

    /// Owns a `llama_model *`. Calls `llama_model_free` on deinit unless
    /// ownership was transferred via `steal()`.
    private final class LlamaModelHandle: @unchecked Sendable {
        private(set) var pointer: OpaquePointer?
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        /// Transfers ownership to the caller. Subsequent deinit is a no-op.
        func steal() -> OpaquePointer? { defer { pointer = nil }; return pointer }
        deinit { if let p = pointer { llama_model_free(p) } }
    }

    /// Owns a `llama_context *`. Calls `llama_free` on deinit unless
    /// ownership was transferred via `steal()`.
    private final class LlamaContextHandle: @unchecked Sendable {
        private(set) var pointer: OpaquePointer?
        let vocabPtr: OpaquePointer?
        init(context: OpaquePointer, vocab: OpaquePointer?) {
            self.pointer = context
            self.vocabPtr = vocab
        }
        /// Transfers ownership to the caller. Subsequent deinit is a no-op.
        func steal() -> OpaquePointer? { defer { pointer = nil }; return pointer }
        deinit { if let p = pointer { llama_free(p) } }
    }

    /// Heap-allocated box used to bridge a Swift async progress handler through the C callback ABI.
    ///
    /// `llama_model_params.progress_callback` is a C function pointer — it cannot capture Swift
    /// context directly. We store the handler in this class, pass an `Unmanaged` retain into
    /// `progress_callback_user_data`, then release it after `llama_model_load_from_file` returns.
    private final class ProgressCallbackContext: @unchecked Sendable {
        let handler: @Sendable (Double) async -> Void
        init(_ handler: @escaping @Sendable (Double) async -> Void) {
            self.handler = handler
        }
    }

    private static func initializeModel(
        at url: URL,
        effectiveContextSize: Int32,
        progressHandler: (@Sendable (Double) async -> Void)? = nil
    ) throws -> LoadedResources {
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0   // Metal not reliable in simulator
        #else
        modelParams.n_gpu_layers = 99  // Offload all layers to Metal
        #endif

        // Wire up the progress callback when a handler is installed.
        // The C callback fires on the loader thread; we bridge to async by
        // creating an unstructured Task so the synchronous C callback returns
        // quickly. The Unmanaged retain is released once the load call returns.
        var callbackContextRef: Unmanaged<ProgressCallbackContext>?
        if let handler = progressHandler {
            let ctx = ProgressCallbackContext(handler)
            callbackContextRef = Unmanaged.passRetained(ctx)
            modelParams.progress_callback_user_data = callbackContextRef!.toOpaque()
            modelParams.progress_callback = { progress, userData -> Bool in
                guard let ptr = userData else { return true }
                // `takeUnretainedValue()` does not bump ARC here — the Task closure below
                // captures `ctx` as a Swift reference, which provides its own ARC retain
                // for the Task's lifetime. The Unmanaged retain managed by the outer defer
                // in `loadModel` is separate and only responsible for keeping the context
                // alive during the synchronous C load call.
                let ctx = Unmanaged<ProgressCallbackContext>.fromOpaque(ptr).takeUnretainedValue()
                let value = Double(progress)
                Task { await ctx.handler(value) }
                return true
            }
        }
        defer { callbackContextRef?.release() }

        guard let rawModel = llama_model_load_from_file(url.path, modelParams) else {
            throw InferenceError.modelLoadFailed(underlying: NSError(
                domain: "LlamaBackend",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load GGUF model from \(url.lastPathComponent)"]
            ))
        }
        let modelHandle = LlamaModelHandle(rawModel)

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(effectiveContextSize)
        ctxParams.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        ctxParams.n_threads_batch = ctxParams.n_threads

        Self.logger.info(
            "LlamaBackend: initializing context at \(effectiveContextSize) tokens (plan-authoritative)"
        )

        // Single attempt. The plan is authoritative — it has already clamped the
        // context to a memory-safe value. If llama_init_from_model still returns
        // nil at this size, we surface a typed error so the caller can request a
        // smaller plan rather than silently allocating half of what was asked for.
        guard let ctx = llama_init_from_model(rawModel, ctxParams) else {
            // modelHandle goes out of scope here → llama_model_free called automatically
            throw InferenceError.modelLoadFailed(underlying: NSError(
                domain: "LlamaBackend",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create llama context at \(effectiveContextSize) tokens. "
                        + "The memory estimate did not account for an allocator failure at this size. "
                        + "Retry with a smaller requested context size.",
                ]
            ))
        }

        let contextHandle = LlamaContextHandle(
            context: ctx,
            vocab: llama_model_get_vocab(rawModel)
        )

        return LoadedResources(
            model: modelHandle,
            context: contextHandle,
            effectiveContextSize: effectiveContextSize
        )
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
        let tokens = tokenize(prompt, addBos: true)
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
                if let text = self.tokenToString(token, invalidUTF8Buffer: &invalidUTF8) {
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

        Self.retainBackend()

        // Defer llama_free off the calling thread — InferenceService is @MainActor,
        // so blocking here would freeze the UI for the duration of the spin-wait.
        // We await the generation task to ensure the C loop has stopped before
        // touching the pointers, preventing a use-after-free crash.
        let newCleanupTask = Task.detached(priority: .utility) {
            await previousCleanup?.value
            await capturedTask?.value
            if let ctx = capturedContext { llama_free(ctx) }
            if let mdl = capturedModel { llama_model_free(mdl) }
            Self.releaseBackend()
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
        let tokens = tokenize(text, addBos: false)
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

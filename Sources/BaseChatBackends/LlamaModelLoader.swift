#if Llama
import Foundation
import LlamaSwift
import os
import BaseChatInference

/// Owns the C-level model load path: parameter setup, progress-callback ABI
/// bridging, and serialization of concurrent loads.
///
/// `llama_model_load_from_file` and `llama_free` are not safe to call
/// concurrently. A `LlamaModelLoader` instance owns `loadSerializationLock`
/// so every load through this loader is serialized against every other load
/// through the same loader. `LlamaBackend` keeps a single instance for its
/// lifetime, so all loads on one backend share this lock.
final class LlamaModelLoader: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )

    /// Serializes concurrent `initializeModel` C-level calls.
    ///
    /// Blocking is acceptable here because the lock is only held inside a
    /// detached task.
    private let loadSerializationLock = NSLock()

    struct LoadedResources: @unchecked Sendable {
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
    final class LlamaModelHandle: @unchecked Sendable {
        private(set) var pointer: OpaquePointer?
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        /// Transfers ownership to the caller. Subsequent deinit is a no-op.
        func steal() -> OpaquePointer? { defer { pointer = nil }; return pointer }
        deinit { if let p = pointer { llama_model_free(p) } }
    }

    /// Owns a `llama_context *`. Calls `llama_free` on deinit unless
    /// ownership was transferred via `steal()`.
    final class LlamaContextHandle: @unchecked Sendable {
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

    /// Synchronous wrapper that holds `loadSerializationLock` while calling the
    /// C-level model init. Called from a detached task so the lock/unlock stays
    /// in a synchronous context (required by Swift 6.3 strict concurrency).
    func serializedModelLoad(
        at url: URL,
        effectiveContextSize: Int32,
        progressHandler: (@Sendable (Double) async -> Void)?
    ) throws -> LoadedResources {
        loadSerializationLock.lock()
        defer { loadSerializationLock.unlock() }
        return try Self.initializeModel(at: url, effectiveContextSize: effectiveContextSize, progressHandler: progressHandler)
    }

    static func initializeModel(
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
}
#endif

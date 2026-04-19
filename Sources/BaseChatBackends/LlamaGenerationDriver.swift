#if Llama
import Foundation
import LlamaSwift
import os
import BaseChatInference

/// Owns the token-generation loop for a single `LlamaBackend.generate()` call.
///
/// `LlamaGenerationDriver` is stateless — every dependency it needs is passed
/// as an explicit parameter to `run()`. This keeps it free of any reference to
/// `LlamaBackend` and makes the generation logic independently testable.
struct LlamaGenerationDriver {

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )

    /// Consecutive identical decoded-token run length that triggers an early exit.
    ///
    /// Small models (e.g. smollm2-135m) can enter visible repetition loops where the same
    /// token string is emitted hundreds of times. The existing `LoopingDetector` catches this
    /// after the fact; this constant lets the generation loop break out as soon as the
    /// repetition is unambiguous, saving KV-cache cycles and wall time.
    private static let maxRepeatWindow = 20

    // MARK: - Run

    /// Executes the generation loop: clears the KV cache, builds the sampler
    /// chain, decodes the prompt in `n_batch`-sized chunks, and runs the
    /// token-generation loop until `maxTokens` are produced, an EOG token is
    /// sampled, or `isCancelled()` returns `true`.
    ///
    /// Yields `.token` events into `continuation` and drives `generationStream`
    /// phase transitions (`.streaming`, `.done`, `.failed`). On any error the
    /// continuation is finished with a thrown `InferenceError` and the stream
    /// phase is set to `.failed`.
    ///
    /// - Parameters:
    ///   - context: Live `llama_context *` snapshot captured under `stateLock`.
    ///   - vocab: Live `llama_vocab *` snapshot captured under `stateLock`.
    ///   - tokens: Tokenized prompt (including BOS) — computed before the Task.
    ///   - maxTokens: Maximum number of new tokens to generate.
    ///   - config: Sampling parameters (temperature, topP, repeatPenalty).
    ///   - markers: Thinking markers for the active template, or nil to disable ThinkingParser.
    ///     When non-nil, `.thinkingToken` / `.thinkingComplete` events are emitted for reasoning
    ///     content and `config.maxThinkingTokens` is enforced.
    ///   - isCancelled: Closure that returns `true` when the caller has requested
    ///     cancellation (combines `Task.isCancelled` and the backend's `Atomic<Bool>`).
    ///   - generationStream: Stream whose phase is updated on the main actor.
    ///   - continuation: Raw stream continuation for yielding events.
    func run(
        context: OpaquePointer,
        vocab: OpaquePointer,
        tokens: [llama_token],
        maxTokens: Int,
        config: GenerationConfig,
        markers: ThinkingMarkers?,
        isCancelled: () -> Bool,
        generationStream: GenerationStream,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
        Self.logger.debug("LlamaGenerationDriver run started")

        // MARK: Batch size

        // `n_batch` caps how many tokens can flow through a single
        // `llama_decode` call. llama.cpp asserts
        // `GGML_ASSERT(n_tokens_all <= cparams.n_batch)` in
        // `llama-context.cpp`, so prompts longer than this must be decoded
        // in chunks. We never set `n_batch` on `ctxParams`, so it inherits
        // llama.cpp's default (2048 at the time of writing).
        let batchSize = max(1, Int(llama_n_batch(context)))

        // MARK: KV cache clear

        // Clear KV cache at the start so state from any prior run (including
        // one terminated by stopGeneration) can't collide with this run's
        // positions.
        if let memory = llama_get_memory(context) {
            llama_memory_clear(memory, false)
        }

        // MARK: Sampler chain setup

        // Sampler chain order matters: penalties → top_k → top_p → temp → dist
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            await MainActor.run { generationStream.setPhase(.failed("Failed to create sampler")) }
            continuation.finish(throwing: InferenceError.inferenceFailure("Failed to create sampler"))
            return
        }
        defer { llama_sampler_free(sampler) }

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

        // MARK: Chunked prompt decode

        // Process prompt in `n_batch`-sized chunks. A single `llama_decode`
        // call cannot exceed `n_batch` tokens, so we stride through the
        // prompt and decode each chunk separately. Only the last token of
        // the final chunk has `logits = 1` — that's the one we sample from
        // to kick off generation.
        var promptDecodeFailed = false
        var promptPos = 0
        while promptPos < tokens.count {
            if isCancelled() { break }

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
            Self.logger.error("Llama prompt decode failed")
            await MainActor.run { generationStream.setPhase(.failed("Failed to decode prompt")) }
            continuation.finish(throwing: InferenceError.inferenceFailure("Failed to decode prompt"))
            return
        }

        // Honour cancellation that fired mid-prompt before entering the
        // generation loop.
        if isCancelled() {
            await MainActor.run { generationStream.setPhase(.done) }
            continuation.finish()
            return
        }

        // MARK: Token generation loop

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

        // ThinkingParser is activated only when markers are provided (i.e. the
        // active prompt template emits reasoning blocks). When `useParser` is
        // false, every decoded token is yielded directly as `.token` without the
        // overhead of tag scanning — important for models that never think.
        let useParser = markers != nil
        var thinkingParser = ThinkingParser(markers: markers ?? .qwen3)
        var thinkingTokenCount = 0
        // Flag set when maxThinkingTokens is reached so we can break the outer loop cleanly.
        var thinkingLimitReached = false

        // Repetition-window state: track the last decoded token string and how
        // many times it has appeared consecutively. Exceeding `maxRepeatWindow`
        // triggers an early exit — no need to run the loop all the way to maxTokens.
        var repeatWindowLast = ""
        var repeatWindowCount = 0

        generationLoop: for iteration in 0..<maxTokens {
            if isCancelled() { break }

            // First iteration samples from the final prompt chunk's logits,
            // which llama.cpp exposes at index -1 ("last available").
            // Subsequent iterations sample from the 1-token gen batch
            // decoded at the end of the previous iteration, at index 0.
            let logitIndex: Int32 = iteration == 0 ? -1 : 0
            let token = llama_sampler_sample(sampler, context, logitIndex)

            if llama_vocab_is_eog(vocab, token) { break }

            // Decode token to text and route through ThinkingParser when active.
            if let text = LlamaTokenization.tokenToString(token, vocab: vocab, invalidUTF8Buffer: &invalidUTF8) {
                // Repetition guard: identical-token run of ≥maxRepeatWindow terminates the loop.
                // This catches small-model repetition loops (e.g. smollm2-135m) early,
                // before the existing post-hoc LoopingDetector has to clean them up.
                if text == repeatWindowLast {
                    repeatWindowCount += 1
                    if repeatWindowCount >= Self.maxRepeatWindow {
                        break generationLoop
                    }
                } else {
                    repeatWindowLast = text
                    repeatWindowCount = 1
                }

                let events: [GenerationEvent] = useParser ? thinkingParser.process(text) : [.token(text)]
                for event in events {
                    if isFirstToken {
                        switch event {
                        case .token, .thinkingToken:
                            // Trigger .streaming on first reasoning token too — models can think
                            // for 30s before any visible output; staying in .connecting is poor UX.
                            await MainActor.run { generationStream.setPhase(.streaming) }
                            isFirstToken = false
                        default: break
                        }
                    }
                    continuation.yield(event)
                    if case .thinkingToken = event {
                        thinkingTokenCount += 1
                        if let limit = config.maxThinkingTokens, thinkingTokenCount >= limit {
                            thinkingLimitReached = true
                            break
                        }
                    }
                }
                if thinkingLimitReached { break generationLoop }
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

            if isCancelled() { break }

            if llama_decode(context, genBatch) != 0 {
                await MainActor.run { generationStream.setPhase(.failed("Decode failed during generation")) }
                continuation.finish(throwing: InferenceError.inferenceFailure("Decode failed during generation"))
                return
            }
        }

        // Flush any bytes held back by the tag-boundary buffer.
        for event in thinkingParser.finalize() {
            continuation.yield(event)
        }

        await MainActor.run { generationStream.setPhase(.done) }
        Self.logger.debug("LlamaGenerationDriver run finished")
        continuation.finish()
    }
}
#endif

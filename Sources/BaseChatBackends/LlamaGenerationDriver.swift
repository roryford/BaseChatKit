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

    /// Maximum phrase length (in tokens) to scan for repeated sequences.
    private static let maxPhraseLen = 20
    /// Minimum consecutive phrase repetitions before early exit.
    private static let minPhraseRepeats = 3
    /// Capacity of the phrase-detection token buffer (maxPhraseLen × minPhraseRepeats + 1).
    private static let phraseWindowCap = maxPhraseLen * minPhraseRepeats + 1

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
    ///   - reuseLen: Number of leading prompt tokens whose KV state was preserved
    ///     from the previous turn by the caller. When > 0, the driver skips
    ///     re-decoding those tokens and emits `.kvCacheReuse(promptTokensReused:)`.
    ///   - maxTokens: Maximum number of new tokens to generate.
    ///   - config: Sampling parameters (temperature, topP, repeatPenalty).
    ///   - markers: Thinking markers for the active template, or nil to disable ThinkingParser.
    ///     When non-nil, `.thinkingToken` / `.thinkingComplete` events are emitted for reasoning
    ///     content and `config.maxThinkingTokens` is enforced.
    ///   - isCancelled: Closure that returns `true` when the caller has requested
    ///     cancellation (combines `Task.isCancelled` and the backend's `Atomic<Bool>`).
    ///   - generationStream: Stream whose phase is updated on the main actor.
    ///   - continuation: Raw stream continuation for yielding events.
    /// Returns `true` when the KV cache is in a coherent state after the call
    /// (success or clean cancellation), `false` when a C decode error occurred
    /// and the KV state should be treated as undefined. Callers must clear their
    /// `sessionKVState` when this returns `false`.
    @discardableResult
    func run(
        context: OpaquePointer,
        vocab: OpaquePointer,
        tokens: [llama_token],
        reuseLen: Int,
        maxTokens: Int,
        config: GenerationConfig,
        markers: ThinkingMarkers?,
        isCancelled: () -> Bool,
        generationStream: GenerationStream,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async -> Bool {
        Self.logger.debug("LlamaGenerationDriver run started")

        // MARK: Batch size

        // `n_batch` caps how many tokens can flow through a single
        // `llama_decode` call. llama.cpp asserts
        // `GGML_ASSERT(n_tokens_all <= cparams.n_batch)` in
        // `llama-context.cpp`, so prompts longer than this must be decoded
        // in chunks. We never set `n_batch` on `ctxParams`, so it inherits
        // llama.cpp's default (2048 at the time of writing).
        let batchSize = max(1, Int(llama_n_batch(context)))

        // MARK: KV cache clear / reuse

        // When reuseLen > 0 the caller (LlamaBackend.generate) has already trimmed
        // the KV tail beyond the shared prefix via llama_memory_seq_rm — so the
        // reused tokens are already decoded at their correct positions and we must
        // NOT clear them. Only do a full clear when there is nothing to reuse.
        if reuseLen == 0, let memory = llama_get_memory(context) {
            llama_memory_clear(memory, false)
        }

        if reuseLen > 0 {
            continuation.yield(.kvCacheReuse(promptTokensReused: reuseLen))
        }

        // MARK: Sampler chain setup

        // Sampler chain order matters: penalties → top_k → top_p → temp → dist
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            await MainActor.run { generationStream.setPhase(.failed("Failed to create sampler")) }
            continuation.finish(throwing: InferenceError.inferenceFailure("Failed to create sampler"))
            return false
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

        // Grammar-constrained sampling: GBNF grammar string from config.
        // Added BEFORE dist so the grammar sampler prunes logits first —
        // dist then picks from only grammar-valid continuations. The chain
        // applies samplers in insertion order, so position matters here.
        //
        // `llama_sampler_init_grammar` returns nil on parse failure (invalid
        // GBNF), in which case we fall through to unconstrained dist sampling
        // rather than crashing. The caller is expected to validate grammar
        // strings before passing them via GenerationConfig.grammar.
        //
        // Teardown: the grammar sampler is owned by `sampler` and freed by
        // the `defer { llama_sampler_free(sampler) }` above — no extra cleanup.
        if let grammarString = config.grammar {
            grammarString.withCString { grammarCStr in
                "root".withCString { rootCStr in
                    if let gs = llama_sampler_init_grammar(vocab, grammarCStr, rootCStr) {
                        llama_sampler_chain_add(sampler, gs)
                    }
                }
            }
        }

        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        // MARK: Chunked prompt decode

        // Process prompt in `n_batch`-sized chunks. A single `llama_decode`
        // call cannot exceed `n_batch` tokens, so we stride through the
        // prompt and decode each chunk separately. Only the last token of
        // the final chunk has `logits = 1` — that's the one we sample from
        // to kick off generation.
        //
        // Start at `reuseLen` to skip the prefix whose KV state was preserved
        // by the caller. When reuseLen == 0 this is equivalent to starting at 0.
        var promptDecodeFailed = false
        var promptPos = reuseLen
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
            return false
        }

        // Honour cancellation that fired mid-prompt before entering the
        // generation loop.
        if isCancelled() {
            await MainActor.run { generationStream.setPhase(.done) }
            continuation.finish()
            return true
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

        // Thinking-marker handling has three modes:
        //
        // 1. Eager — `markers != nil` (template advertises thinking). Every decoded
        //    token flows through `ThinkingParser` from the first byte.
        //
        // 2. Sniff — `markers == nil` (template does NOT advertise thinking). A small
        //    byte window is accumulated and scanned for `<think>`. If the marker
        //    appears inside the budget, the captured prefix is replayed through a
        //    fresh `ThinkingParser(.qwen3)` and the driver switches to eager mode for
        //    the remainder of the stream. This catches DeepSeek-R1 GGUFs that use a
        //    non-ChatML prompt template but still emit `<think>…</think>` content.
        //
        // 3. Passthrough — sniff budget exhausted without a marker. Every subsequent
        //    token yields `.token` with no tag scanning, matching non-reasoning
        //    models' fast path.
        //
        // `useParser` starts true for mode 1 and flips true for mode 2 if sniffing
        // detects a marker. Once true it never reverts.
        //
        // Special case: `config.maxThinkingTokens == 0` disables thinking entirely
        // (issue #597). Even when `markers` is non-nil, the parser stays off and
        // sniffing is skipped, so every decoded token flows straight to `.token`.
        // The model may still emit raw `<think>` / `</think>` substrings, but the
        // driver routes them as visible text rather than `.thinkingToken` events.
        let thinkingDisabled = config.maxThinkingTokens == 0
        var useParser = !thinkingDisabled && markers != nil
        var thinkingParser = ThinkingParser(markers: markers ?? .qwen3)
        var thinkingTokenCount = 0
        // Flag set when maxThinkingTokens is reached so we can break the outer loop cleanly.
        var thinkingLimitReached = false

        // Lazy-sniff state. Only consulted when `markers == nil` at entry.
        // Buffer grows until either `<think>` is found or `sniffBudgetBytes` bytes
        // have been seen without a match. The open-tag suffix needs to be kept
        // across the boundary so a partial `<thin` followed by `k>` still matches.
        let sniffBudgetBytes = 64
        let sniffOpenTag = ThinkingMarkers.qwen3.open  // "<think>"
        let sniffEnabled = !thinkingDisabled && markers == nil
        var sniffBuffer = ""
        var sniffDone = !sniffEnabled   // true when sniffing has concluded (match or giveup)

        // Repetition-window state: track the last decoded token string and how
        // many times it has appeared consecutively. Exceeding `maxRepeatWindow`
        // triggers an early exit — no need to run the loop all the way to maxTokens.
        var repeatWindowLast = ""
        var repeatWindowCount = 0

        // Phrase-level repetition state: a bounded sliding window (Array, evicted
        // via removeFirst — O(n) but cap=61 so cost is negligible) of the last
        // `phraseWindowCap` decoded token strings. After each token is appended,
        // the tail is scanned for back-to-back phrase repetitions of lengths 2–20.
        var phraseWindow: [String] = []
        phraseWindow.reserveCapacity(Self.phraseWindowCap + 1)

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
                // Single-token repetition guard: identical-token run of ≥maxRepeatWindow
                // terminates the loop. Catches small-model repetition loops (e.g.
                // smollm2-135m emitting " " hundreds of times) before the post-hoc
                // LoopingDetector has to clean them up.
                if text == repeatWindowLast {
                    repeatWindowCount += 1
                    if repeatWindowCount >= Self.maxRepeatWindow {
                        break generationLoop
                    }
                } else {
                    repeatWindowLast = text
                    repeatWindowCount = 1
                }

                // Phrase-level repetition guard: catch multi-token loops (2–20 tokens)
                // that the single-token window misses. Live fuzz runs on smollm2-135m
                // surfaced loops with repeating units such as ASCII-art phrases, HTML
                // timestamp blocks, and RTL override sequences.
                phraseWindow.append(text)
                if phraseWindow.count > Self.phraseWindowCap {
                    phraseWindow.removeFirst()
                }
                let maxScanLen = min(Self.maxPhraseLen, phraseWindow.count / Self.minPhraseRepeats)
                if maxScanLen >= 2 {
                    for phraseLen in 2...maxScanLen {
                        if Self.tailRepeats(phraseWindow, phraseLen: phraseLen, minRepeats: Self.minPhraseRepeats) {
                            break generationLoop
                        }
                    }
                }

                // Build the list of events this token emits. Three paths, matching the
                // three thinking-marker modes documented at the top of the loop:
                var events: [GenerationEvent] = []
                if useParser {
                    events = thinkingParser.process(text)
                } else if !sniffDone {
                    sniffBuffer += text
                    if sniffBuffer.contains(sniffOpenTag) {
                        // Hit — replay the full sniff buffer through the parser so its
                        // pre-<think> prefix yields `.token` events and the opening tag
                        // opens a thinking block with the post-tag remainder streaming
                        // as `.thinkingToken`.
                        useParser = true
                        sniffDone = true
                        events = thinkingParser.process(sniffBuffer)
                        sniffBuffer = ""
                    } else if sniffBuffer.count >= sniffBudgetBytes {
                        // Budget exhausted without a marker — flush as visible text and
                        // stop sniffing for the remainder of the stream.
                        events = [.token(sniffBuffer)]
                        sniffBuffer = ""
                        sniffDone = true
                    }
                    // else: still sniffing, emit nothing this iteration
                } else {
                    events = [.token(text)]
                }

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
                return false
            }
        }

        // Flush any unflushed sniffer bytes as visible text — the stream ended
        // before the sniff budget was reached or a `<think>` was found.
        if !sniffBuffer.isEmpty {
            continuation.yield(.token(sniffBuffer))
            sniffBuffer = ""
        }

        // Flush any bytes held back by the tag-boundary buffer. Only matters when
        // the parser was ever engaged — skipping the call when `useParser` stayed
        // false avoids yielding spurious events from an untouched parser.
        if useParser {
            for event in thinkingParser.finalize() {
                continuation.yield(event)
            }
        }

        await MainActor.run { generationStream.setPhase(.done) }
        Self.logger.debug("LlamaGenerationDriver run finished")
        continuation.finish()
        return true
    }

    // MARK: - Phrase Detection

    /// Returns true when the tail of `window` contains `minRepeats` consecutive
    /// identical phrases of length `phraseLen`.
    private static func tailRepeats(_ window: [String], phraseLen: Int, minRepeats: Int) -> Bool {
        let needed = phraseLen * minRepeats
        guard window.count >= needed else { return false }
        let n = window.count
        let phrase = window[(n - phraseLen)...]
        for rep in 1..<minRepeats {
            let start = n - phraseLen * (rep + 1)
            let end   = n - phraseLen * rep
            guard start >= 0 else { return false }
            if window[start..<end].elementsEqual(phrase) == false { return false }
        }
        return true
    }
}
#endif

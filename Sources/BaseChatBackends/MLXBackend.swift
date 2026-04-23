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
        supportsNativeJSONMode: false,
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
    /// Access only under `stateLock`.
    private var _conversationHistory: [(role: String, content: String)] = []

    // MARK: - Load Progress

    /// Guarded by `stateLock`. Set by `setLoadProgressHandler(_:)` before each load.
    ///
    /// `loadModelContainer(from: URL)` in `mlx-swift-lm` provides no granular progress hook
    /// on local directory loads — the progress handler overload is only available for download
    /// paths. We emit synthetic bookends (0.0 before, 1.0 after) so `InferenceService` can
    /// distinguish "load started" from "load complete" rather than showing a flat 0% spinner.
    private var _loadProgressHandler: (@Sendable (Double) async -> Void)?

    // MARK: - Configuration

    /// Policy controlling MLX's GPU buffer cache size. See `MLXCachePolicy`.
    /// Defaults to `.auto`, which picks a sensible value based on device RAM.
    public let cachePolicy: MLXCachePolicy

    // MARK: - Init

    public init(cachePolicy: MLXCachePolicy = .auto) {
        self.cachePolicy = cachePolicy
    }

    // MARK: - Architecture Allowlist

    /// Canonical `model_type` values that `mlx-swift-lm`'s `LLMTypeRegistry.shared`
    /// can serve as chat/instruct LMs. Anything outside this set — CLIP, SigLIP,
    /// Whisper, BERT embeddings, Qwen2-VL vision encoders, etc. — is refused at
    /// load time via `InferenceError.unsupportedModelArchitecture`.
    ///
    /// Sourced from `LLMTypeRegistry.shared` in mlx-swift-lm
    /// (`Libraries/MLXLLM/LLMModelFactory.swift`). When mlx-swift-lm adds a new
    /// LM architecture, update this list to match so the preflight doesn't reject
    /// a freshly supported model.
    static let supportedLMArchitectures: Set<String> = [
        "mistral", "llama", "phi", "phi3", "phimoe",
        "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n",
        "qwen2", "qwen3", "qwen3_moe", "qwen3_next",
        "qwen3_5", "qwen3_5_moe", "qwen3_5_text",
        "minicpm", "starcoder2", "cohere", "openelm", "internlm2",
        "deepseek_v3", "granite", "granitemoehybrid",
        "mimo", "mimo_v2_flash", "minimax",
        "glm4", "glm4_moe", "glm4_moe_lite",
        "acereason", "falcon_h1", "bitnet", "smollm3",
        "ernie4_5", "lfm2", "lfm2_moe",
        "baichuan_m1", "exaone4", "gpt_oss",
        "lille-130m", "olmoe", "olmo2", "olmo3",
        "bailing_moe", "nanochat", "nemotron_h",
        "afmoe", "jamba_3b", "mistral3", "apertus",
    ]

    /// Reads `config.json` at `url` and throws
    /// `InferenceError.unsupportedModelArchitecture` if the declared `model_type`
    /// is not a chat/instruct LM. If `config.json` is missing or unreadable the
    /// check is a no-op — mlx-swift-lm's own load path will then surface the
    /// real error (missing weights, malformed directory, etc.).
    static func validateArchitecture(at url: URL) throws {
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Missing / malformed config.json: let the MLX load path produce the
            // real diagnostic rather than masking it with a false architecture error.
            return
        }

        let modelType = (json["model_type"] as? String)?
            .lowercased()
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !modelType.isEmpty, supportedLMArchitectures.contains(modelType) {
            return
        }

        // Some HF repos omit model_type but include an `architectures` array
        // (e.g. ["LlamaForCausalLM"]). Accept the load if any entry's snake_case
        // prefix matches the allowlist — this keeps older snapshots working.
        if let archs = json["architectures"] as? [String] {
            for arch in archs {
                let normalized = arch.lowercased()
                if Self.supportedLMArchitectures.contains(where: { normalized.hasPrefix($0) }) {
                    return
                }
            }
        }

        let reported = modelType.isEmpty ? (json["architectures"] as? [String])?.joined(separator: ",") ?? "unknown" : modelType
        throw InferenceError.unsupportedModelArchitecture(reported)
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        assert(plan.verdict != .deny,
               "ModelLoadPlan was denied; callers must check verdict before invoking backend")
        // MLX reads context sizing from the model container; `plan` is informational
        // here and kept for consistency with the protocol. Future work could honour
        // `plan.effectiveContextSize` to cap generation length.
        unloadModel()

        // Preflight: refuse non-LM architectures up front so a CLIP/SigLIP/Whisper
        // snapshot can't crash MLX mid-generation or silently produce garbage tokens.
        // We read config.json directly rather than letting mlx-swift-lm attempt the
        // load and fail — mlx-swift-lm's own error message ("unsupportedModelType")
        // surfaces through `modelLoadFailed(underlying:)` and hides the root cause
        // from the UI. Throwing `.unsupportedModelArchitecture` here makes the reason
        // explicit and lets `ChatError` map it to `.selectModel`.
        try Self.validateArchitecture(at: url)

        let progressHandler = withStateLock { _loadProgressHandler }

        // Signal "load started". The `mlx-swift-lm` local-directory API has no granular
        // progress hook, so we emit a 0.0 bookend here and a 1.0 bookend after the load
        // completes. This gives InferenceService enough signal to animate a progress
        // indicator rather than showing a flat 0% spinner for the full load duration.
        await progressHandler?(0.0)

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
            // Signal load complete before returning so InferenceService sees 1.0
            // before it clears the handler and flips isModelLoaded.
            await progressHandler?(1.0)
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

        // Build messages in chat format, using full conversation history when available
        // so multi-turn exchanges retain context. Falls back to the bare prompt when
        // setConversationHistory has not been called (e.g. direct unit-test calls).
        let conversationHistory = withStateLock { _conversationHistory }
        let messages: [[String: String]] = {
            var msgs: [[String: String]] = []
            if let systemPrompt, !systemPrompt.isEmpty {
                msgs.append(["role": "system", "content": systemPrompt])
            }
            if !conversationHistory.isEmpty {
                for msg in conversationHistory {
                    msgs.append(["role": msg.role, "content": msg.content])
                }
            } else {
                msgs.append(["role": "user", "content": prompt])
            }
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

                // Use the caller-configured markers when provided; fall back to .qwen3 (Qwen3/DeepSeek-R1).
                // mlx-swift-lm exposes no tokenizer API to auto-detect markers at generation time.
                // TODO: expose thinkingMarkers as a generate() parameter when Gemma 4 / other models land.
                //
                // `config.maxThinkingTokens == 0` disables thinking entirely (issue #597). Even when
                // `thinkingMarkers` is set, the parser stays off and every chunk flows through as
                // `.token`. Raw `<think>` / `</think>` substrings surface as visible text rather
                // than being split into `.thinkingToken` events.
                let thinkingDisabled = config.maxThinkingTokens == 0
                var thinkingParser = ThinkingParser(markers: config.thinkingMarkers ?? .qwen3)
                let useParser = !thinkingDisabled && config.thinkingMarkers != nil

                // Enforces `config.maxThinkingTokens` with the same semantics as
                // LlamaGenerationDriver: a thinking model that runs away on a 16 GB
                // Mac can OOM mid-generation, so when the configured budget is hit
                // we stop emitting further thinking tokens and break out of the
                // MLX stream. Visible `.token` events are never counted toward
                // this budget. See issue #550.
                var thinkingTokenCount = 0
                var thinkingLimitReached = false

                let mlxStream = try await modelContainer.generate(
                    messages: messages,
                    parameters: generateConfig
                )
                outer: for await generation in mlxStream {
                    if Task.isCancelled { break }
                    if let text = generation.chunk {
                        for event in useParser ? thinkingParser.process(text) : [GenerationEvent.token(text)] {
                            if isFirstToken {
                                switch event {
                                case .token, .thinkingToken:
                                    await MainActor.run { generationStream.setPhase(.streaming) }
                                    isFirstToken = false
                                default: break
                                }
                            }
                            // Only count visible output tokens toward maxOutputTokens limit
                            if case .token = event { outputTokenCount += 1 }
                            continuation.yield(event)
                            if case .thinkingToken = event {
                                thinkingTokenCount += 1
                                if let limit = config.maxThinkingTokens, thinkingTokenCount >= limit {
                                    thinkingLimitReached = true
                                    break
                                }
                            }
                        }
                        if thinkingLimitReached { break outer }
                        if let limit = outputLimit, outputTokenCount >= limit { break }
                    }
                }
                // Flush any bytes held back at the tag-boundary buffer.
                for event in thinkingParser.finalize() {
                    continuation.yield(event)
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
            _conversationHistory = []
            return had
        }
        if hadContainer {
            Memory.clearCache()
        }
        Self.logger.info("MLX backend unloaded")
    }
}

// MARK: - ConversationHistoryReceiver

extension MLXBackend: ConversationHistoryReceiver {
    public func setConversationHistory(_ history: [(role: String, content: String)]) {
        withStateLock { _conversationHistory = history }
    }
}

// MARK: - LoadProgressReporting

extension MLXBackend: LoadProgressReporting {
    /// Installs a synthetic-bookend progress handler. Because `mlx-swift-lm`'s local-directory
    /// load path exposes no granular progress, the handler receives `0.0` when the load begins
    /// and `1.0` when it completes successfully. This is enough for `InferenceService` to show
    /// a non-zero progress indicator rather than a flat 0% spinner.
    public func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?) {
        withStateLock { _loadProgressHandler = handler }
    }
}
#endif

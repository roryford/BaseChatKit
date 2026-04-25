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
        supportsToolCalling: true,
        supportsStructuredOutput: false,
        supportsNativeJSONMode: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: true,
        memoryStrategy: .resident,
        maxOutputTokens: 4096,
        supportsStreaming: true,
        isRemote: false,
        supportsThinking: true
    )

    // MARK: - Private

    /// Access only under `stateLock`.
    private var _modelContainer: (any MLXModelContainerProtocol)?
    /// Access only under `stateLock`.
    private var _generationTask: Task<Void, Never>?
    /// Access only under `stateLock`.
    private var _conversationHistory: [(role: String, content: String)] = []
    /// The tool-call dialect detected for the currently loaded model.
    /// Set by `loadModel(from:plan:)` via `MLXToolDialect.detect(at:)`.
    /// Access only under `stateLock`.
    private var _dialect: MLXToolDialect = .unknown
    /// Tool-aware conversation history, set by `setToolAwareHistory(_:)`.
    /// When non-nil this supersedes `_conversationHistory` for message building.
    /// Access only under `stateLock`.
    private var _toolAwareHistory: [ToolAwareHistoryEntry]?

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
        "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n", "gemma4",
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
            let detectedDialect = MLXToolDialect.detect(at: url)
            withStateLock {
                _modelContainer = container
                _dialect = detectedDialect
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
        let (conversationHistory, toolAwareHistory, dialect) = withStateLock {
            (_conversationHistory, _toolAwareHistory, _dialect)
        }

        // For Qwen 2.5: serialize tool definitions into a <tools>…</tools> block
        // appended to the system message content. This is the standard Qwen chat
        // template mechanism for exposing tools to the model.
        let effectiveSystemPrompt: String? = {
            guard !config.tools.isEmpty, dialect == .qwen25 else {
                return systemPrompt
            }
            let toolObjects: [[String: Any]] = config.tools.map { tool -> [String: Any] in
                var function_: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                ]
                if let paramsData = try? JSONEncoder().encode(tool.parameters),
                   let paramsObj = try? JSONSerialization.jsonObject(with: paramsData) {
                    function_["parameters"] = paramsObj
                } else {
                    function_["parameters"] = ["type": "object", "properties": [String: Any]()]
                }
                return ["type": "function", "function": function_]
            }
            let toolsJSON: String
            if let data = try? JSONSerialization.data(withJSONObject: toolObjects, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                toolsJSON = str
            } else {
                toolsJSON = "[]"
            }
            let toolBlock = "\n\n# Tools\n\nYou may call one or more functions to assist with the user query. Don't make assumptions about what values to plug into functions. Here are the available tools:\n\n<tools>\n\(toolsJSON)\n</tools>\n\nFor each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags as follows:\n<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call>"
            let base = systemPrompt ?? ""
            return base + toolBlock
        }()

        // All messages are encoded as plain [String: String] dictionaries because
        // MLXModelContainerProtocol.generate(messages:) requires [[String: String]].
        // For Qwen 2.5 tool history, tool calls are text-encoded into content fields
        // using the same <tool_call>…</tool_call> format the model emits.
        let messages: [[String: String]] = {
            var msgs: [[String: String]] = []
            if let sp = effectiveSystemPrompt, !sp.isEmpty {
                msgs.append(["role": "system", "content": sp])
            }
            if let toolHistory = toolAwareHistory, !toolHistory.isEmpty {
                // Encode tool-aware history entries into the Qwen text format.
                for entry in toolHistory {
                    msgs.append(Self.encodeToolAwareEntryAsText(entry, dialect: dialect))
                }
            } else if !conversationHistory.isEmpty {
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
                let useThinkingParser = !thinkingDisabled && config.thinkingMarkers != nil

                // Instantiate the tool-call parser when tools are configured and the
                // loaded model speaks a known tool-call dialect. The parser is a no-op
                // pass-through when tools are empty or the dialect is unknown.
                let useToolParser = !config.tools.isEmpty && dialect != .unknown
                var toolParser = MLXToolCallParser()

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
                        // Stage 1: tool-call parsing (suppresses tokens inside <tool_call>…</tool_call>).
                        // Stage 2: thinking parsing on remaining .token events.
                        let stageOneEvents: [GenerationEvent] = useToolParser
                            ? toolParser.process(text)
                            : [.token(text)]

                        for event in stageOneEvents {
                            // Apply thinking parser only to visible token events.
                            let finalEvents: [GenerationEvent]
                            if case .token(let tokenText) = event, useThinkingParser {
                                finalEvents = thinkingParser.process(tokenText)
                            } else {
                                finalEvents = [event]
                            }

                            for finalEvent in finalEvents {
                                if isFirstToken {
                                    switch finalEvent {
                                    case .token, .thinkingToken, .toolCall:
                                        await MainActor.run { generationStream.setPhase(.streaming) }
                                        isFirstToken = false
                                    default: break
                                    }
                                }
                                // Only count visible output tokens toward maxOutputTokens limit.
                                // Tool call events do not count as output tokens.
                                if case .token = finalEvent { outputTokenCount += 1 }
                                continuation.yield(finalEvent)
                                if case .thinkingToken = finalEvent {
                                    thinkingTokenCount += 1
                                    if let limit = config.maxThinkingTokens, thinkingTokenCount >= limit {
                                        thinkingLimitReached = true
                                        break
                                    }
                                }
                            }
                        }
                        if thinkingLimitReached { break outer }
                        if let limit = outputLimit, outputTokenCount >= limit { break }
                    }
                }
                // Flush any bytes held back at tag-boundary buffers.
                if useToolParser {
                    for event in toolParser.finalize() {
                        if case .token(let tokenText) = event, useThinkingParser {
                            for finalEvent in thinkingParser.process(tokenText) {
                                continuation.yield(finalEvent)
                            }
                        } else {
                            continuation.yield(event)
                        }
                    }
                }
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
            _toolAwareHistory = nil
            _dialect = .unknown
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
        withStateLock {
            _conversationHistory = history
            // Clear any previously stored tool-aware history so the simpler path takes
            // effect when the orchestrator calls the non-tool-aware setter.
            _toolAwareHistory = nil
        }
    }
}

// MARK: - ToolCallingHistoryReceiver

extension MLXBackend: ToolCallingHistoryReceiver {
    /// Stores a tool-aware conversation history for the next `generate()` call.
    ///
    /// When set, this supersedes the plain `(role, content)` history provided
    /// via `setConversationHistory(_:)`. The entries are encoded into the
    /// Qwen 2.5 text format (or plain content for `.unknown` dialects) before
    /// being passed to the MLX generate path.
    public func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        withStateLock { _toolAwareHistory = messages }
    }
}

// MARK: - Tool-Aware Entry Encoding

extension MLXBackend {
    /// Encodes a ``ToolAwareHistoryEntry`` into a plain `[String: String]` message
    /// compatible with `MLXModelContainerProtocol.generate(messages:)`.
    ///
    /// For the Qwen 2.5 dialect:
    /// - Assistant entries with `toolCalls` have the calls serialised as
    ///   `<tool_call>{"name":…,"arguments":…}</tool_call>` appended to (or
    ///   replacing) the textual content.
    /// - Tool-role entries (carrying a ``ToolResult``) are represented as
    ///   `role: "tool"` with the result content. The MLX chat template for
    ///   Qwen maps the `tool` role to an `<tool_response>` block internally.
    ///
    /// For the `.unknown` dialect (and plain text turns) the entry collapses to
    /// a simple `{role, content}` pair.
    static func encodeToolAwareEntryAsText(
        _ entry: ToolAwareHistoryEntry,
        dialect: MLXToolDialect
    ) -> [String: String] {
        // For non-Qwen dialects or plain turns, fall back to the bare shape.
        guard dialect == .qwen25 else {
            return ["role": entry.role, "content": entry.content]
        }

        if let calls = entry.toolCalls, !calls.isEmpty {
            // Assistant turn that triggered tool calls: encode calls as text.
            var parts: [String] = []
            if !entry.content.isEmpty {
                parts.append(entry.content)
            }
            for call in calls {
                let argsValue: Any
                if let data = call.arguments.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    argsValue = parsed
                } else {
                    argsValue = [String: Any]()
                }
                let callObj: [String: Any] = ["name": call.toolName, "arguments": argsValue]
                if let data = try? JSONSerialization.data(withJSONObject: callObj),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    parts.append("<tool_call>\n\(jsonStr)\n</tool_call>")
                }
            }
            return ["role": "assistant", "content": parts.joined(separator: "\n")]
        }

        // Tool result turn: pass role and content as-is.
        // The Qwen tokenizer template handles `role: "tool"` natively.
        return ["role": entry.role, "content": entry.content]
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

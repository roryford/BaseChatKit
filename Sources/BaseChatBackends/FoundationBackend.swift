#if canImport(FoundationModels)
import Foundation
import FoundationModels
import os
import BaseChatCore

/// Apple FoundationModels inference backend for on-device Apple Intelligence models.
///
/// Uses Apple's built-in language model via the FoundationModels framework.
/// Unlike other backends, this does not load external model files — the model
/// is provided by the system. The `loadModel(from:contextSize:)` URL parameter
/// is ignored; it simply creates a new session and verifies availability.
///
/// Requires iOS 26+ / macOS 26+.
@available(iOS 26, macOS 26, *)
public final class FoundationBackend: InferenceBackend, @unchecked Sendable {

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "inference"
    )

    // MARK: - State

    public var isModelLoaded: Bool {
        withStateLock { _isModelLoaded }
    }

    public var isGenerating: Bool {
        withStateLock { _isGenerating }
    }

    // MARK: - Capabilities

    public let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: false,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false,
        memoryStrategy: .external,
        maxOutputTokens: 4096,
        supportsStreaming: true,
        isRemote: false
    )

    // MARK: - Private

    private let stateLock = NSLock()
    private var _isModelLoaded = false
    private var _isGenerating = false
    private var session: LanguageModelSession?
    private var generationTask: Task<Void, Never>?
    /// Tracks the system prompt used to create the current session, so we only
    /// recreate when the prompt actually changes.
    private var currentSystemPrompt: String?

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - Init

    public init() {}

    // MARK: - Availability

    /// Whether the system language model is available on this device.
    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, contextSize: Int32) async throws {
        unloadModel()

        guard SystemLanguageModel.default.availability == .available else {
            throw InferenceError.inferenceFailure(
                "Apple Intelligence model is not available on this device"
            )
        }

        // Availability can report .available even when the session cannot
        // actually run inference (e.g. simulator, or Apple Intelligence not
        // fully set up). Probe with a minimal request to verify.
        //
        // Probe session history: `LanguageModelSession.respond(to:)` accumulates
        // conversation turns inside the session object. We must NOT store the probe
        // session as the backend's active session — if we did, the first real user
        // message would see the "Hi / <probe response>" exchange as prior context.
        // Instead we discard the probe session after the availability check; `generate()`
        // will create a fresh session on its first call (session == nil triggers that path).
        let probeSession = LanguageModelSession()
        do {
            _ = try await probeSession.respond(to: "Hi")
        } catch {
            Self.logger.warning("Foundation model probe failed: \(error)")
            throw InferenceError.inferenceFailure(
                "Apple Intelligence model is not ready. Ensure Apple Intelligence is enabled in Settings > Apple Intelligence & Siri."
            )
        }
        // Intentionally NOT assigning probeSession to self.session — see comment above.
        // session remains nil; generate() will create a clean session on first use.

        withStateLock {
            _isModelLoaded = true
        }
        Self.logger.info("Foundation backend loaded")
    }

    public func unloadModel() {
        stopGeneration()
        withStateLock {
            session = nil
            currentSystemPrompt = nil
            _isModelLoaded = false
            _isGenerating = false
        }
        Self.logger.info("Foundation backend unloaded")
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let activeSession: LanguageModelSession = try withStateLock {
            guard _isModelLoaded else {
                throw InferenceError.inferenceFailure("No model loaded")
            }
            guard !_isGenerating else {
                throw InferenceError.alreadyGenerating
            }
            _isGenerating = true

            // Reuse the existing session to preserve conversation history.
            // Only recreate if the system prompt changed or no session exists.
            let needsNewSession = session == nil || systemPrompt != currentSystemPrompt
            if needsNewSession {
                if let systemPrompt, !systemPrompt.isEmpty {
                    session = LanguageModelSession(instructions: systemPrompt)
                } else {
                    session = LanguageModelSession()
                }
                currentSystemPrompt = systemPrompt
            }

            return session!
        }

        Self.logger.debug("Foundation generate started")

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let generationStream = GenerationStream(stream)

        let task = Task { [weak self, generationStream] in
            guard let backend = self else {
                continuation.finish()
                return
            }

            defer {
                backend.withStateLock {
                    backend._isGenerating = false
                    backend.generationTask = nil
                }
                Self.logger.debug("Foundation generate finished")
            }

            do {
                var options = GenerationOptions()
                options.temperature = Double(config.temperature)

                let responseStream = activeSession.streamResponse(
                    to: prompt,
                    options: options
                )

                let outputLimit = config.maxOutputTokens
                var outputTokenCount = 0
                var previousText = ""
                var isFirstToken = true
                for try await partial in responseStream {
                    if Task.isCancelled { break }

                    let currentText = partial.content
                    if currentText.count > previousText.count {
                        let newContent = String(
                            currentText[currentText.index(
                                currentText.startIndex,
                                offsetBy: previousText.count
                            )...]
                        )
                        if isFirstToken {
                            await MainActor.run { generationStream.setPhase(.streaming) }
                            isFirstToken = false
                        }
                        continuation.yield(.token(newContent))
                        previousText = currentText

                        // Approximate token count using the conservative 3-char heuristic.
                        // Stops runaway generation for open-ended prompts.
                        if let limit = outputLimit {
                            outputTokenCount += max(1, newContent.count / 3)
                            if outputTokenCount >= limit {
                                Self.logger.info("Output token limit (\(limit)) reached")
                                break
                            }
                        }
                    }
                }
                await MainActor.run { generationStream.setPhase(.done) }
            } catch {
                if !Task.isCancelled {
                    Self.logger.error("Foundation generation error: \(error)")
                    await MainActor.run { generationStream.setPhase(.failed(error.localizedDescription)) }
                    continuation.finish(throwing: error)
                    return
                }
                await MainActor.run { generationStream.setPhase(.done) }
            }

            continuation.finish()
        }

        withStateLock {
            generationTask = task
        }

        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }

        return generationStream
    }

    // MARK: - Conversation Reset

    public func resetConversation() {
        withStateLock {
            session = nil
            currentSystemPrompt = nil
        }
        Self.logger.info("Foundation conversation reset")
    }

    // MARK: - Control

    public func stopGeneration() {
        let task = withStateLock { () -> Task<Void, Never>? in
            defer { generationTask = nil }
            return generationTask
        }
        task?.cancel()

        // Discard the session after cancellation so the partial response
        // doesn't corrupt the conversation history for subsequent turns.
        withStateLock {
            session = nil
            currentSystemPrompt = nil
        }
    }

}

// MARK: - TokenizerVendor

@available(iOS 26, macOS 26, *)
extension FoundationBackend: TokenizerVendor {
    /// Vends a synchronous tokenizer using a conservative 3-chars-per-token heuristic
    /// calibrated for Apple's Foundation Model tokenizer (which produces more tokens
    /// per character than the default 4-char heuristic).
    public var tokenizer: any TokenizerProvider { FoundationTokenizer.shared }
}

/// Conservative synchronous tokenizer for Apple Foundation Models.
///
/// Apple's tokenizer produces roughly 1 token per 2.5-3 characters for English text.
/// Using 3 chars/token is a safe estimate that slightly overestimates token usage,
/// which is preferable to underestimating and hitting context overflow errors.
@available(iOS 26, macOS 26, *)
struct FoundationTokenizer: TokenizerProvider {
    static let shared = FoundationTokenizer()
    func tokenCount(_ text: String) -> Int {
        max(1, text.count / 3)
    }
}
#endif

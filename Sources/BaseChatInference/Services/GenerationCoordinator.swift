import Foundation
import Observation

/// Owns the generation queue, in-flight request tracking, prompt formatting,
/// and generation lifecycle management.
///
/// This is an internal implementation detail of `BaseChatInference`.
/// `InferenceService` delegates all generation operations to this coordinator
/// and preserves the unchanged public API.
@Observable
@MainActor
final class GenerationCoordinator {

    // MARK: - Published State

    /// Whether the coordinator has an active generation in progress.
    ///
    /// `internal` storage, exposed as `public` via `InferenceService.isGenerating`.
    private(set) var isGenerating = false

    // MARK: - Dependencies

    weak var provider: (any GenerationContextProvider)?

    // MARK: - Queue Types (Private)

    private struct QueuedRequest {
        let token: GenerationRequestToken
        let priority: GenerationPriority
        let sessionID: UUID?
        let messages: [(role: String, content: String)]
        let systemPrompt: String?
        let config: GenerationConfig
        let stream: GenerationStream
    }

    // MARK: - Queue State (Private)

    private var nextGenerationToken: GenerationRequestToken = .zero
    private var requestQueue: [QueuedRequest] = []
    private var activeRequest: QueuedRequest?
    private var activeTask: Task<Void, Never>?
    private var continuations: [GenerationRequestToken: AsyncThrowingStream<GenerationEvent, Error>.Continuation] = [:]
    private let maxQueueDepth = 8

    // MARK: - Computed

    var hasQueuedRequests: Bool { !requestQueue.isEmpty }

    var lastTokenUsage: (promptTokens: Int, completionTokens: Int)? {
        (provider?.currentBackend as? TokenUsageProvider)?.lastUsage
    }

    // MARK: - Initializers

    nonisolated init() {}

    // MARK: - Generation (Non-Queued)

    /// Generates text from a message history, streaming tokens via the active backend.
    ///
    /// This is the low-level, non-queued entry point. It does **not** participate
    /// in the generation queue.
    func generate(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048
    ) throws -> GenerationStream {
        guard let backend = provider?.currentBackend else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        let config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens
        )

        let prompt: String
        let effectiveSystemPrompt: String?

        if backend.capabilities.requiresPromptTemplate {
            let template = provider?.selectedPromptTemplate ?? .chatML
            prompt = template.format(
                messages: messages,
                systemPrompt: systemPrompt
            )
            effectiveSystemPrompt = nil
        } else {
            prompt = messages.last(where: { $0.role == "user" })?.content ?? ""
            effectiveSystemPrompt = systemPrompt
        }

        if let historyReceiver = backend as? ConversationHistoryReceiver {
            historyReceiver.setConversationHistory(messages)
        }

        return try backend.generate(
            prompt: prompt,
            systemPrompt: effectiveSystemPrompt,
            config: config
        )
    }

    // MARK: - Generation Queue

    func enqueue(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil
    ) throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        guard provider?.currentBackend != nil, provider?.isBackendLoaded == true else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        guard requestQueue.count < maxQueueDepth else {
            throw InferenceError.inferenceFailure("Generation queue is full")
        }

        let token = GenerationRequestToken(rawValue: nextGenerationToken.rawValue + 1)
        nextGenerationToken = token

        var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation!
        let rawStream = AsyncThrowingStream<GenerationEvent, Error> { continuation = $0 }
        let stream = GenerationStream(rawStream)
        stream.setPhase(.queued)
        continuations[token] = continuation

        let config = GenerationConfig(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            maxOutputTokens: maxOutputTokens
        )

        let request = QueuedRequest(
            token: token,
            priority: priority,
            sessionID: sessionID,
            messages: messages,
            systemPrompt: systemPrompt,
            config: config,
            stream: stream
        )

        if let insertIdx = requestQueue.firstIndex(where: { $0.priority < priority }) {
            requestQueue.insert(request, at: insertIdx)
        } else {
            requestQueue.append(request)
        }

        drainQueue()
        return (token: token, stream: stream)
    }

    /// Processes the next queued request if no generation is active.
    private func drainQueue() {
        guard activeRequest == nil, !requestQueue.isEmpty else { return }

        let next = requestQueue.removeFirst()

        // Thermal gate: drop background requests under thermal pressure.
        if next.priority == .background {
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical {
                let throttleError = InferenceError.inferenceFailure("Thermal throttle")
                Log.inference.warning("Dropping background generation \(next.token): thermal state \(thermal.rawValue)")
                next.stream.setPhase(.failed(throttleError.localizedDescription))
                finishAndDiscard(next.token, error: throttleError)
                drainQueue()
                return
            }
        }

        activeRequest = next
        isGenerating = true
        next.stream.setPhase(.connecting)

        activeTask = Task { [weak self] in
            guard let self else { return }

            var thrownError: Error?
            defer {
                if let continuation = self.continuations.removeValue(forKey: next.token) {
                    if let thrownError {
                        continuation.finish(throwing: thrownError)
                    } else {
                        continuation.finish()
                    }
                }
                if self.activeRequest?.token == next.token {
                    self.activeRequest = nil
                    self.activeTask = nil
                    self.isGenerating = false
                    self.drainQueue()
                }
            }

            do {
                let backendStream = try self.generate(
                    messages: next.messages,
                    systemPrompt: next.systemPrompt,
                    temperature: next.config.temperature,
                    topP: next.config.topP,
                    repeatPenalty: next.config.repeatPenalty,
                    maxOutputTokens: next.config.maxOutputTokens
                )

                for try await event in backendStream.events {
                    guard !Task.isCancelled else { break }
                    if case .token = event, next.stream.phase != .streaming {
                        next.stream.setPhase(.streaming)
                    }
                    self.continuations[next.token]?.yield(event)
                }

                if Task.isCancelled {
                    next.stream.setPhase(.failed("Cancelled"))
                } else {
                    next.stream.setPhase(.done)
                }
            } catch {
                thrownError = error
                if Task.isCancelled {
                    next.stream.setPhase(.failed("Cancelled"))
                } else {
                    next.stream.setPhase(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func finishAndDiscard(_ token: GenerationRequestToken, error: Error? = nil) {
        if let error {
            continuations[token]?.finish(throwing: error)
        } else {
            continuations[token]?.finish(throwing: CancellationError())
        }
        continuations.removeValue(forKey: token)
    }

    func cancel(_ token: GenerationRequestToken) {
        if activeRequest?.token == token {
            provider?.currentBackend?.stopGeneration()
            activeTask?.cancel()
            activeTask = nil
            activeRequest?.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(token)
            activeRequest = nil
            isGenerating = false
            drainQueue()
        } else if let idx = requestQueue.firstIndex(where: { $0.token == token }) {
            let req = requestQueue.remove(at: idx)
            req.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(token)
        }
    }

    func discardRequests(notMatching sessionID: UUID) {
        requestQueue.removeAll { req in
            guard let reqSession = req.sessionID, reqSession != sessionID else { return false }
            req.stream.setPhase(.failed("Session changed"))
            finishAndDiscard(req.token, error: InferenceError.inferenceFailure("Session changed"))
            return true
        }
        if let active = activeRequest,
           let activeSession = active.sessionID,
           activeSession != sessionID {
            cancel(active.token)
        }
    }

    func stopGeneration() {
        provider?.currentBackend?.stopGeneration()
        activeTask?.cancel()
        activeTask = nil
        if let active = activeRequest {
            active.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(active.token, error: CancellationError())
        }
        activeRequest = nil
        isGenerating = false

        for req in requestQueue {
            req.stream.setPhase(.failed("Cancelled"))
            finishAndDiscard(req.token, error: CancellationError())
        }
        requestQueue.removeAll()
    }

}

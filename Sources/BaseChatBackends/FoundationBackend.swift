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

    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    // MARK: - Capabilities

    public let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    // MARK: - Private

    private var session: LanguageModelSession?
    private var generationTask: Task<Void, Never>?

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

        session = LanguageModelSession()
        isModelLoaded = true
        Self.logger.info("Foundation backend loaded")
    }

    public func unloadModel() {
        stopGeneration()
        session = nil
        isModelLoaded = false
        isGenerating = false
        Self.logger.info("Foundation backend unloaded")
    }

    // MARK: - Generation

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded, session != nil else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        guard !isGenerating else {
            throw InferenceError.alreadyGenerating
        }

        isGenerating = true
        Self.logger.debug("Foundation generate started")

        // Create a fresh session with instructions for each generation.
        // LanguageModelSession accumulates conversation history, so a new
        // session ensures a clean context each time.
        let activeSession: LanguageModelSession
        if let systemPrompt, !systemPrompt.isEmpty {
            activeSession = LanguageModelSession(instructions: systemPrompt)
        } else {
            activeSession = LanguageModelSession()
        }
        session = activeSession

        return AsyncThrowingStream { [weak self] continuation in
            let task = Task {
                defer {
                    self?.isGenerating = false
                    Self.logger.debug("Foundation generate finished")
                }

                do {
                    var options = GenerationOptions()
                    options.temperature = Double(config.temperature)

                    let stream = activeSession.streamResponse(
                        to: prompt,
                        options: options
                    )

                    var previousText = ""
                    for try await partial in stream {
                        if Task.isCancelled { break }

                        let currentText = partial.content
                        if currentText.count > previousText.count {
                            let newContent = String(
                                currentText[currentText.index(
                                    currentText.startIndex,
                                    offsetBy: previousText.count
                                )...]
                            )
                            continuation.yield(newContent)
                            previousText = currentText
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        Self.logger.error("Foundation generation error: \(error)")
                        continuation.finish(throwing: error)
                        return
                    }
                }

                continuation.finish()
            }

            self?.generationTask = task

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Control

    public func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }
}

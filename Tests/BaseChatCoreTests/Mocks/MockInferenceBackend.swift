import Foundation
@testable import BaseChatCore

final class MockInferenceBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = false
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities

    // Configurable behavior
    var tokensToYield: [String] = ["Hello", " world"]
    var shouldThrowOnGenerate: Error? = nil
    var shouldThrowOnLoad: Error? = nil

    // Track calls
    var loadModelCallCount = 0
    var generateCallCount = 0
    var stopCallCount = 0
    var unloadCallCount = 0

    // Capture last generate arguments
    var lastPrompt: String?
    var lastSystemPrompt: String?
    var lastConfig: GenerationConfig?

    init(capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )) {
        self.capabilities = capabilities
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        loadModelCallCount += 1
        if let error = shouldThrowOnLoad { throw error }
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> AsyncThrowingStream<String, Error> {
        generateCallCount += 1
        lastPrompt = prompt
        lastSystemPrompt = systemPrompt
        lastConfig = config
        if let error = shouldThrowOnGenerate { throw error }
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }

        isGenerating = true
        let tokens = tokensToYield

        return AsyncThrowingStream { [weak self] continuation in
            Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                self?.isGenerating = false
                continuation.finish()
            }
        }
    }

    func stopGeneration() {
        stopCallCount += 1
        isGenerating = false
    }

    func unloadModel() {
        unloadCallCount += 1
        isModelLoaded = false
        isGenerating = false
    }
}

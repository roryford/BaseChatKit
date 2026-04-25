#if Fuzz && Ollama
import Foundation
import BaseChatFuzz
import BaseChatBackends
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that instantiates a fresh `OllamaBackend`
/// configured against a local Ollama server. Picks the first installed model
/// whose name contains `modelHint`, or the first available model if no hint
/// is given.
///
/// Lives in `Sources/fuzz-chat/` rather than `BaseChatFuzz` so the engine
/// target stays free of `BaseChatBackends` (MLX/Llama) and `BaseChatTestSupport`
/// dependencies. Lifts cleanly to a shared location once more factories land.
public struct OllamaFuzzFactory: FuzzBackendFactory {
    public let modelHint: String?
    public let baseURL: URL

    public init(modelHint: String?, baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.modelHint = modelHint
        self.baseURL = baseURL
    }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard let models = HardwareRequirements.listOllamaModels() else {
            throw CLIError("No Ollama server reachable at \(baseURL.absoluteString). Start with: ollama serve")
        }
        let hintedModel: String? = modelHint.flatMap { hint in
            HardwareRequirements.findOllamaModel(nameContains: hint)
        }
        guard let model = hintedModel ?? models.first else {
            throw CLIError("No Ollama model installed. Pull one with: ollama pull qwen3.5:4b")
        }
        let backend = OllamaBackend()
        backend.configure(baseURL: baseURL, modelName: model)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        // Ollama presents the model's emitted thinking via its native streaming;
        // the canonical qwen3 markers are the right baseline for the detector.
        let markers = RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: model,
            modelURL: URL(string: "ollama:" + model)!,
            backendName: "ollama",
            templateMarkers: markers
        )
    }
}
#endif

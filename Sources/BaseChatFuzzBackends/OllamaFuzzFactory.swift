#if Ollama
import Foundation
import BaseChatBackends
import BaseChatFuzz
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that instantiates a fresh `OllamaBackend`
/// configured against a local Ollama server.
///
/// When used directly, the factory honours the existing
/// `HardwareRequirements.findOllamaModel` selection rules, including the
/// `OLLAMA_TEST_MODEL` environment override. `makeCampaignFactory(modelHint:)`
/// preserves the CLI's rotate-all default when no explicit model hint is given.
public struct OllamaFuzzFactory: FuzzBackendFactory {
    public let modelHint: String?
    public let baseURL: URL
    public let environment: [String: String]

    public init(
        modelHint: String? = nil,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.modelHint = modelHint
        self.baseURL = baseURL
        self.environment = environment
    }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard let models = HardwareRequirements.listOllamaModels() else {
            throw FuzzBackendFactoryError(
                "No Ollama server reachable at \(baseURL.absoluteString). Start with: ollama serve"
            )
        }
        let model: String?
        if let hint = Self.normalizedModelHint(modelHint) {
            model = HardwareRequirements.findOllamaModel(nameContains: hint, environment: environment)
        } else {
            model = HardwareRequirements.findOllamaModel(environment: environment) ?? models.first
        }
        guard let model else {
            throw FuzzBackendFactoryError(
                "No Ollama model installed. Pull one with: ollama pull qwen3.5:4b"
            )
        }
        // FIXME(#714): expected deprecation warning until the next major
        // release flips `Ollama` out of default traits. The fuzz harness
        // is internal infrastructure that exercises the trait-gated init
        // directly.
        let backend = OllamaBackend()
        backend.configure(baseURL: baseURL, modelName: model)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        let markers = RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: model,
            modelURL: URL(string: "ollama:" + model)!,
            backendName: "ollama",
            templateMarkers: markers
        )
    }

    /// Builds the campaign factory the CLI uses for Ollama runs.
    ///
    /// - When `modelHint` is `nil`, empty, or `"all"`: enumerates every installed
    ///   Ollama model, sorts by UTF-8 byte order, and wraps them in a
    ///   `RotatingFuzzFactory` so the runner round-robins one model per
    ///   iteration.
    /// - When `modelHint` names a specific model: returns a single pinned factory
    ///   so callers preserve the pre-rotation behaviour.
    public static func makeCampaignFactory(
        modelHint: String? = nil,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any FuzzBackendFactory {
        guard let normalizedHint = normalizedModelHint(modelHint) else {
            guard let models = HardwareRequirements.listOllamaModels() else {
                throw FuzzBackendFactoryError(
                    "No Ollama server reachable at \(baseURL.absoluteString). Start with: ollama serve"
                )
            }
            guard !models.isEmpty else {
                throw FuzzBackendFactoryError(
                    "No Ollama model installed. Pull one with: ollama pull qwen3.5:4b"
                )
            }
            let children: [any FuzzBackendFactory] = models.sorted().map {
                OllamaFuzzFactory(modelHint: $0, baseURL: baseURL, environment: environment)
            }
            return RotatingFuzzFactory(children: children)
        }

        return OllamaFuzzFactory(modelHint: normalizedHint, baseURL: baseURL, environment: environment)
    }

    private static func normalizedModelHint(_ modelHint: String?) -> String? {
        guard var modelHint else { return nil }
        modelHint = modelHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelHint.isEmpty else { return nil }
        guard modelHint.lowercased() != "all" else { return nil }
        return modelHint
    }
}
#endif

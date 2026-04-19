#if Llama
import Foundation
import BaseChatFuzz
import BaseChatBackends
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that instantiates `LlamaBackend` against the
/// first GGUF model found in `~/Documents/Models/`.
///
/// `llama_backend_init` is a process-global one-shot, so this factory always
/// uses a single model for the whole campaign — `--model all` is a no-op.
/// See FUZZING.md § Backends for the single-model constraint rationale.
public struct LlamaFuzzFactory: FuzzBackendFactory {
    public init() {}

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw CLIError(
                "No GGUF model found in ~/Documents/Models/. "
                    + "Download a GGUF model (e.g. via the demo app) to use --backend llama."
            )
        }
        let backend = LlamaBackend()
        try await backend.loadModel(
            from: modelURL,
            plan: .testStub(effectiveContextSize: 4096)
        )
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: modelURL.lastPathComponent,
            modelURL: modelURL,
            backendName: "llama",
            templateMarkers: nil
        )
    }
}
#endif

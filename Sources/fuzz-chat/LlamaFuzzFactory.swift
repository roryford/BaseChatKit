#if Llama && Fuzz
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
///
/// Implemented as a `final class` (not a `struct`) so that `teardown()` can
/// await the same `LlamaBackend` instance that `makeHandle()` loaded without
/// capturing it through the `FuzzRunner.BackendHandle`. `@unchecked Sendable`
/// is safe: `backend` is written exactly once (in `makeHandle`) and read once
/// (in `teardown`); both calls are serialised by the CLI's single async task.
public final class LlamaFuzzFactory: FuzzBackendFactory, @unchecked Sendable {
    private var backend: LlamaBackend?

    public init() {}

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw CLIError(
                "No GGUF model found in ~/Documents/Models/. "
                    + "Download a GGUF model (e.g. via the demo app) to use --backend llama."
            )
        }
        let b = LlamaBackend()
        try await b.loadModel(
            from: modelURL,
            plan: .testStub(effectiveContextSize: 4096)
        )
        backend = b
        return FuzzRunner.BackendHandle(
            backend: b,
            modelId: modelURL.lastPathComponent,
            modelURL: modelURL,
            backendName: "llama",
            templateMarkers: nil
        )
    }

    /// Awaits `LlamaBackend.unloadAndWait()` before the process exits so that
    /// ggml-metal teardown completes in-order and avoids the SIGABRT from
    /// `ggml-metal-device.m` resource-set assertion failure (issue #391).
    public func teardown() async {
        await backend?.unloadAndWait()
    }
}
#endif

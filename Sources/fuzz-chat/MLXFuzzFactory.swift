#if MLX
import Foundation
import BaseChatFuzz
import BaseChatBackends
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that instantiates `MLXBackend` against the
/// first MLX model directory found in `~/Documents/Models/`.
///
/// Requires real Apple Silicon hardware with a Metal-capable GPU — does not work
/// in the iOS Simulator or headless CI without a GPU context. Call sites must
/// gate on `HardwareRequirements.hasMetalDevice` before constructing this factory.
///
/// Implemented as a `final class` (not a `struct`) so that `teardown()` can
/// await the same `MLXBackend` instance that `makeHandle()` loaded without
/// capturing it through the `FuzzRunner.BackendHandle`. `@unchecked Sendable`
/// is safe: `backend` is written exactly once (in `makeHandle`) and read once
/// (in `teardown`); both calls are serialised by the CLI's single async task.
public final class MLXFuzzFactory: FuzzBackendFactory, @unchecked Sendable {
    private var backend: MLXBackend?

    public init() {}

    public var supportsDeterministicReplay: Bool { true }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard HardwareRequirements.hasMetalDevice else {
            throw CLIError(
                "MLXFuzzFactory requires a Metal-capable GPU. "
                    + "Run on Apple Silicon with a real Metal device (not the simulator)."
            )
        }
        guard let modelURL = HardwareRequirements.findMLXModelDirectory() else {
            throw CLIError(
                "No MLX model found in ~/Documents/Models/. "
                    + "Download an MLX model (e.g. via the demo app) to use --backend mlx."
            )
        }
        let b = MLXBackend(cachePolicy: .auto)
        try await b.loadModel(
            from: modelURL,
            plan: .systemManaged(requestedContextSize: 4096)
        )
        backend = b
        return FuzzRunner.BackendHandle(
            backend: b,
            modelId: modelURL.lastPathComponent,
            modelURL: modelURL,
            backendName: "mlx",
            templateMarkers: nil
        )
    }

    /// Unloads the MLX model and clears the GPU buffer cache before the process
    /// exits. Ordered teardown prevents Metal resource-set assertion failures
    /// that can occur when the process exits while buffers are still resident.
    public func teardown() async {
        backend?.unloadModel()
    }
}
#endif

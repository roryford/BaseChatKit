#if canImport(FoundationModels)
import Foundation
import BaseChatFuzz
import BaseChatBackends
import BaseChatInference

/// `FuzzBackendFactory` conformance that instantiates `FoundationBackend`.
///
/// The Apple Intelligence system model is always resident — no model file is needed.
/// Skips gracefully when Apple Intelligence is unavailable (not enabled, or not
/// supported on this device) rather than crashing the campaign.
///
/// Requires macOS 26 / iOS 26. Call sites must be guarded with
/// `#available(macOS 26, iOS 26, *)`.
@available(macOS 26, iOS 26, *)
public struct FoundationFuzzFactory: FuzzBackendFactory {
    public init() {}

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard FoundationBackend.isAvailable else {
            throw CLIError(
                "Apple Intelligence is not available. "
                    + "Enable it in Settings > Apple Intelligence & Siri."
            )
        }
        let backend = FoundationBackend()
        let modelURL = URL(string: "foundation:system")!
        try await backend.loadModel(from: modelURL, plan: .cloud())
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: "apple-intelligence",
            modelURL: modelURL,
            backendName: "foundation",
            templateMarkers: nil
        )
    }
}
#endif

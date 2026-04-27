#if canImport(FoundationModels) && Fuzz
import Foundation
import BaseChatFuzz
import BaseChatBackends
import BaseChatInference

/// `FuzzBackendFactory` conformance that instantiates `FoundationBackend`.
///
/// The Apple Intelligence system model is always resident — no model file is needed.
/// Throws `CLIError` when Apple Intelligence is unavailable (not enabled, or not
/// supported on this device), which `FuzzChatCLI` surfaces as an early-exit error
/// rather than letting the campaign run 0 iterations silently.
///
/// Requires macOS 26 / iOS 26. Call sites must be guarded with
/// `#available(macOS 26, iOS 26, *)`.
@available(macOS 26, iOS 26, *)
public struct FoundationFuzzFactory: FuzzBackendFactory {
    public init() {}

    /// Apple Intelligence runs on-device and produces identical output for
    /// identical inputs, so findings are replayable. Stated explicitly per
    /// the #561 spec rather than relying on the protocol-extension default,
    /// to make intent obvious to readers comparing factories side-by-side.
    public var supportsDeterministicReplay: Bool { true }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard FoundationBackend.isAvailable else {
            throw CLIError(
                "Apple Intelligence is not available. "
                    + "Enable it in Settings > Apple Intelligence & Siri."
            )
        }
        let backend = FoundationBackend()
        let modelURL = URL(string: "foundation:system")!
        // .systemManaged correctly signals OS-owned memory with no KV-cache estimate;
        // .cloud() would be semantically misleading for a local on-device backend.
        try await backend.loadModel(from: modelURL, plan: .systemManaged(requestedContextSize: 0))
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

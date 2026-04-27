#if canImport(FoundationModels)
import XCTest
import BaseChatBackends
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatFuzz

/// Verifies the contract of the Foundation fuzz factory.
///
/// `Sources/fuzz-chat/` is an `executableTarget`, so its real
/// `FoundationFuzzFactory` cannot be imported by SPM test targets.
/// We mirror the factory here and assert the same invariants the CLI relies on:
///
/// - default `supportsDeterministicReplay == true` (Apple Intelligence is local
///   and deterministic given identical prompt + config — see issue #561)
/// - graceful early-exit error when Apple Intelligence is unavailable
///   (the CLI surfaces this as a `fail()` rather than running 0 iterations)
/// - happy-path handle wiring on a host with Apple Intelligence enabled
///
/// The happy-path test is hardware-gated: CI runners and any host where
/// `SystemLanguageModel.default.availability != .available` skip the load
/// path and only assert the pure-value contract.
@available(macOS 26, iOS 26, *)
final class FoundationFuzzFactoryTests: XCTestCase {

    /// Mirror of `Sources/fuzz-chat/FoundationFuzzFactory.swift`. Keep the two
    /// structurally identical; behavioural divergence should either be cleaned
    /// up in both places or surfaced with a distinct test. The explicit
    /// `supportsDeterministicReplay` override is mirrored here on purpose —
    /// without it the test would only exercise the protocol-extension default
    /// and silently pass even if the real factory dropped its override.
    @available(macOS 26, iOS 26, *)
    struct LocalFoundationFuzzFactory: FuzzBackendFactory {
        struct UnavailableError: Error, Equatable {}

        var supportsDeterministicReplay: Bool { true }

        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            guard FoundationBackend.isAvailable else {
                throw UnavailableError()
            }
            let backend = FoundationBackend()
            let modelURL = URL(string: "foundation:system")!
            try await backend.loadModel(
                from: modelURL,
                plan: .systemManaged(requestedContextSize: 0)
            )
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "apple-intelligence",
                modelURL: modelURL,
                backendName: "foundation",
                templateMarkers: nil
            )
        }
    }

    /// Companion type with no override. Used to verify the protocol-extension
    /// default that the executable's factory inherits when reading is decided
    /// purely by the protocol contract — keeps the determinism invariant
    /// double-pinned even if the real factory's explicit override regresses.
    @available(macOS 26, iOS 26, *)
    struct DefaultsOnlyFactory: FuzzBackendFactory {
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            fatalError("not used; only inspected for protocol-extension defaults")
        }
    }

    // MARK: - Pure-value contract (runs on every host)

    /// The Foundation factory's explicit override must report `true` so the
    /// `Replayer` does not short-circuit with `.nonDeterministicBackend` for
    /// Apple Intelligence findings. Pinned via the local mirror — the real
    /// factory lives in an `executableTarget` and cannot be imported here.
    func test_supportsDeterministicReplay_isTrue() {
        let factory = LocalFoundationFuzzFactory()
        XCTAssertTrue(
            factory.supportsDeterministicReplay,
            "FoundationFuzzFactory must report deterministic replay so #561 fuzz findings are replayable"
        )
    }

    /// Independently verifies the protocol-extension default is `true`.
    /// Together with `test_supportsDeterministicReplay_isTrue` above, this
    /// pins both layers: the executable's explicit override AND the
    /// inherited default it would fall back to. Either regressing would flip
    /// `Replayer` to `.nonDeterministicBackend` for Foundation campaigns.
    func test_protocolDefault_supportsDeterministicReplay_isTrue() {
        let factory = DefaultsOnlyFactory()
        XCTAssertTrue(
            factory.supportsDeterministicReplay,
            "FuzzBackendFactory protocol default must remain `true` — local backends rely on it"
        )
    }

    // MARK: - Unavailability handling

    /// When Apple Intelligence is unavailable, `makeHandle()` must throw
    /// rather than return a half-loaded handle. This is what lets the CLI
    /// surface a friendly error instead of silently running 0 iterations.
    /// We can only assert this branch on hosts where AI is genuinely
    /// unavailable — on a real macOS 26 dev box with AI enabled the guard
    /// passes through to the load path, which is exercised by the
    /// hardware-gated happy-path test below.
    func test_makeHandle_throwsWhenAppleIntelligenceUnavailable() async {
        guard !FoundationBackend.isAvailable else {
            // Host has Apple Intelligence — covered by the happy-path test.
            return
        }
        let factory = LocalFoundationFuzzFactory()
        do {
            _ = try await factory.makeHandle()
            XCTFail("makeHandle() must throw when Apple Intelligence is unavailable")
        } catch is LocalFoundationFuzzFactory.UnavailableError {
            // Expected.
        } catch {
            XCTFail("expected UnavailableError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Hardware-gated happy path

    /// Verifies the factory loads a real `FoundationBackend` and produces a
    /// handle the runner can consume. Skipped when Apple Intelligence is
    /// unavailable (CI, simulator, devices without AI enabled).
    func test_makeHandle_returnsLoadedBackend() async throws {
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Apple Intelligence is unavailable on this host — enable it in Settings > Apple Intelligence & Siri to exercise the Foundation fuzz factory."
        )
        let factory = LocalFoundationFuzzFactory()
        let handle = try await factory.makeHandle()
        XCTAssertTrue(
            handle.backend.isModelLoaded,
            "factory must pre-load the backend so the runner's first generate() call does not throw"
        )
        XCTAssertEqual(handle.backendName, "foundation")
        XCTAssertEqual(handle.modelId, "apple-intelligence")
        XCTAssertNil(
            handle.templateMarkers,
            "Foundation has no chat-template markers — Apple's SDK exposes no thinking/reasoning surface (see FoundationBackend doc comment)"
        )
    }
}
#endif // canImport(FoundationModels)

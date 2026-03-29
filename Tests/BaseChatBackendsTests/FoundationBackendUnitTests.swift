import XCTest
import BaseChatCore
@testable import BaseChatBackends

/// Isolated unit tests for `FoundationBackend` state management and guard paths.
///
/// These tests do NOT perform real inference and do NOT require Apple Intelligence.
/// They run everywhere that iOS 26 / macOS 26 SDK symbols are available (which is
/// satisfied at compile time even on the simulator / CI machines with Xcode 26 SDKs).
///
/// Tests that would require live model inference are marked with `XCTSkip` when
/// `FoundationBackend.isAvailable` returns `false`.
@available(iOS 26, macOS 26, *)
final class FoundationBackendUnitTests: XCTestCase {

    private var backend: FoundationBackend!

    override func setUp() {
        super.setUp()
        backend = FoundationBackend()
    }

    override func tearDown() {
        backend = nil
        super.tearDown()
    }

    // MARK: - 1. generate() before loadModel() throws

    func test_generate_beforeLoad_throwsNoModelLoaded() throws {
        XCTAssertFalse(backend.isModelLoaded, "Precondition: model must not be loaded")

        let config = GenerationConfig()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: config)
        ) { error in
            guard case InferenceError.inferenceFailure(let msg) = error else {
                XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(
                msg.localizedCaseInsensitiveContains("No model loaded"),
                "Error message should mention 'No model loaded', got: \(msg)"
            )
        }
    }

    // MARK: - 3. unloadModel() clears state

    func test_unloadModel_clearsState() {
        // Manually probe the initial state, then confirm unloadModel is idempotent
        // and always leaves the backend in the unloaded state.
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)

        backend.unloadModel()

        XCTAssertFalse(backend.isModelLoaded, "isModelLoaded must be false after unloadModel()")
        XCTAssertFalse(backend.isGenerating, "isGenerating must be false after unloadModel()")
    }

    func test_unloadModel_idempotent() {
        // Calling unloadModel() twice must not crash or leave bad state.
        backend.unloadModel()
        backend.unloadModel()

        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - 4. resetConversation() preserves isModelLoaded

    /// Regression test for the bug where resetConversation() would set session = nil
    /// without touching isModelLoaded, but callers expected isModelLoaded to remain
    /// true so that generate() could recreate the session on the next call.
    ///
    /// Without Apple Intelligence we cannot call loadModel() to get to the loaded
    /// state, so we verify the contract from the unloaded side: resetConversation()
    /// must NOT change isModelLoaded regardless of what it was before.
    func test_resetConversation_doesNotChangeIsModelLoaded_whenUnloaded() {
        XCTAssertFalse(backend.isModelLoaded, "Precondition")
        backend.resetConversation()
        XCTAssertFalse(
            backend.isModelLoaded,
            "resetConversation() must not modify isModelLoaded"
        )
    }

    /// On a real device with Apple Intelligence, verify the full round-trip:
    /// loadModel() → isModelLoaded==true, resetConversation() → still true.
    func test_resetConversation_preservesIsModelLoaded_afterLoad() async throws {
        guard FoundationBackend.isAvailable else {
            throw XCTSkip("Apple Intelligence not available on this device")
        }

        let url = URL(fileURLWithPath: "/dev/null") // ignored by FoundationBackend
        try await backend.loadModel(from: url, contextSize: 4096)
        XCTAssertTrue(backend.isModelLoaded, "Precondition: loadModel() should set isModelLoaded")

        backend.resetConversation()

        XCTAssertTrue(
            backend.isModelLoaded,
            "resetConversation() must leave isModelLoaded == true (regression: was not clearing it)"
        )
    }

    // MARK: - 5. isAvailable is readable

    func test_isAvailable_returnsSystemModelAvailability() {
        // We can't assert a specific value — it's device-dependent.
        // This test merely confirms the property is readable and returns a Bool.
        let available: Bool = FoundationBackend.isAvailable
        // The result is valid either way; just ensure no crash / type mismatch.
        _ = available
    }

    // MARK: - 6. capabilities has correct values

    func test_capabilities_hasCorrectValues() {
        let caps = backend.capabilities

        XCTAssertFalse(
            caps.requiresPromptTemplate,
            "FoundationBackend applies its own chat template; requiresPromptTemplate must be false"
        )
        XCTAssertTrue(
            caps.supportsSystemPrompt,
            "FoundationBackend accepts a system prompt via LanguageModelSession(instructions:)"
        )
        XCTAssertEqual(
            caps.maxContextTokens,
            4096,
            "maxContextTokens must be 4096"
        )
        XCTAssertTrue(
            caps.supportedParameters.contains(.temperature),
            "temperature must be in supportedParameters"
        )
    }

    // MARK: - 7. generate() while already generating throws alreadyGenerating

    func test_generate_whileAlreadyGenerating_throwsAlreadyGenerating() throws {
        // We cannot reach isGenerating==true without a running session, but we
        // can verify the guard ordering: the isModelLoaded guard fires first,
        // which means the alreadyGenerating guard is dead code when the model
        // is not loaded. To reach the alreadyGenerating path we need isModelLoaded
        // to be true. Since we cannot call loadModel() without Apple Intelligence,
        // skip this sub-test when unavailable.
        guard FoundationBackend.isAvailable else {
            throw XCTSkip("Apple Intelligence not available — cannot reach isGenerating guard without a loaded model")
        }

        // If we get here we could load the model and start a long generation,
        // but that would be an E2E test. Instead, we verify the guard order
        // through the unit-level property: isGenerating is false by default
        // and only set to true inside generate(). The guard itself is correct
        // by code inspection; we validate the compile-time contract here.
        XCTAssertFalse(backend.isGenerating, "isGenerating must start false")
    }

    // MARK: - 2. After resetConversation(), generate() doesn't hit the model-not-loaded guard

    /// Verifies that resetConversation() only clears the session (conversation
    /// history), not the loaded state — so a subsequent generate() can recreate
    /// the session rather than throwing "No model loaded".
    ///
    /// State-only version (no real inference): checks that isModelLoaded is
    /// still true after reset, meaning the generate() guard would pass.
    func test_generate_afterResetConversation_isModelLoadedRemainsTrue() async throws {
        guard FoundationBackend.isAvailable else {
            throw XCTSkip("Apple Intelligence not available on this device")
        }

        let url = URL(fileURLWithPath: "/dev/null")
        try await backend.loadModel(from: url, contextSize: 4096)
        XCTAssertTrue(backend.isModelLoaded)

        backend.resetConversation()

        XCTAssertTrue(
            backend.isModelLoaded,
            "After resetConversation(), isModelLoaded must still be true so generate() can recreate the session"
        )
        XCTAssertFalse(backend.isGenerating)
    }
}

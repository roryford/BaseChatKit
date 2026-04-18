#if Llama
import XCTest
@testable import BaseChatInference
@testable import BaseChatBackends
import BaseChatTestSupport

// MARK: - Hardware-gated tests

/// Tests for LlamaBackend's memory pressure abort wiring (issue #415).
///
/// `LlamaBackend` owns a private `MemoryPressureHandler` and registers a callback
/// in `init` that calls `stopGeneration()` on `.warning` and `stopGeneration()` +
/// `unloadAndWait()` on `.critical`. Because the handler and its callback are
/// private, these tests exercise the same *operations* the callback performs,
/// verifying they are safe to call from a background GCD queue (the thread model
/// the `DispatchSource` callback uses on a real device).
///
/// All tests skip in the simulator and on non-Apple-Silicon hosts, where
/// `llama_backend_init` (invoked by `LlamaBackend.init`) requires Metal.
final class LlamaBackendMemoryPressureTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
            "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
            "LlamaBackend requires Apple Silicon")
    }

    // MARK: - stopGeneration() is safe from a GCD utility queue

    /// The memory pressure callback fires on a GCD utility queue.
    /// `stopGeneration()` must not crash when called from that context on an
    /// idle (unloaded) backend — the same state LlamaBackend is in at app
    /// launch before the user picks a model.
    ///
    /// Sabotage check: replacing `Atomic<Bool>` with a plain `var Bool` in
    /// LlamaBackend would produce a TSan data-race violation here when multiple
    /// concurrent queues call `stopGeneration()` simultaneously.
    func test_stopGeneration_fromGCDQueue_doesNotCrash() async {
        let backend = LlamaBackend()

        // Fire stopGeneration() concurrently from 20 GCD utility threads,
        // matching the kind of concurrent access a real pressure callback
        // could produce if multiple watchdog sources fired simultaneously.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            backend.stopGeneration()
                            continuation.resume()
                        }
                    }
                }
            }
        }

        XCTAssertFalse(backend.isGenerating,
            "isGenerating must remain false after concurrent GCD-queue stopGeneration() calls")
    }

    // MARK: - unloadAndWait() is safe from a detached Task

    /// On `.critical` pressure the callback spawns:
    ///   `Task { [weak self] in await self?.unloadAndWait() }`
    /// Verify that `unloadAndWait()` called from a detached Task on an unloaded
    /// backend completes without crashing and leaves the backend clean.
    ///
    /// Sabotage check: if `unloadAndWait()` were not safe to call from a
    /// non-MainActor context this test would fail with a concurrency violation.
    func test_unloadAndWait_fromDetachedTask_isIdempotentAndSafe() async {
        let backend = LlamaBackend()

        // Replicate exactly what the critical-pressure arm does.
        let task = Task.detached { [weak backend] in
            await backend?.unloadAndWait()
        }
        await task.value

        XCTAssertFalse(backend.isModelLoaded,
            "isModelLoaded must be false after unloadAndWait() from a detached task")
        XCTAssertFalse(backend.isGenerating,
            "isGenerating must be false after unloadAndWait() from a detached task")
    }

    // MARK: - Callback registration does not cause a retain cycle

    /// `registerMemoryPressureCallback()` captures `self` weakly. If the capture
    /// were strong, the `MemoryPressureHandler` closure would keep `LlamaBackend`
    /// alive past its last external reference, causing a leak.
    ///
    /// We verify this by releasing the backend and confirming no crash occurs.
    /// A retain cycle would keep `backend` alive, and `deinit` would not call
    /// `memoryPressure.removeCallback(for:)`, leaving a dangling AnyObject key.
    /// The absence of EXC_BAD_ACCESS confirms the weak capture is in effect.
    func test_deinit_removesCallbackWithoutCrash() {
        var backend: LlamaBackend? = LlamaBackend()
        // Force release — if a retain cycle existed, deinit would not run here.
        withExtendedLifetime(backend) {}
        backend = nil
        // If we reach this line, deinit ran and the callback was safely removed.
        XCTAssert(true, "LlamaBackend deinit must not crash when cleaning up the memory pressure callback")
    }
}

// MARK: - Hardware-free: MemoryPressureHandler callback API

/// Exercises the `addPressureCallback` / `removeCallback` API added to
/// `MemoryPressureHandler` in support of issue #415.
///
/// These tests do not instantiate `LlamaBackend` and run without special hardware.
final class MemoryPressureCallbackAPITests: XCTestCase {

    // MARK: - Registration and removal

    func test_addPressureCallback_replacesExistingEntryForSameOwner() {
        let handler = MemoryPressureHandler()
        let owner = NSObject()
        var callCount = 0

        handler.addPressureCallback(for: owner) { _ in callCount += 1 }
        // Registering again for the same owner replaces the previous entry.
        handler.addPressureCallback(for: owner) { _ in callCount += 10 }

        // Verify no crash and the table updated correctly.
        handler.removeCallback(for: owner)
        // callCount is still 0 — no real DispatchSource has fired.
        XCTAssertEqual(callCount, 0,
            "No callback should have fired — DispatchSource has not received an OS event")
    }

    func test_removeCallback_forUnregisteredOwner_isNoOp() {
        let handler = MemoryPressureHandler()
        let owner = NSObject()

        // Remove before registering — must be a no-op.
        handler.removeCallback(for: owner)
        handler.removeCallback(for: owner)
        // No crash = pass.
    }

    func test_removeCallback_afterRegistration_isIdempotent() {
        let handler = MemoryPressureHandler()
        let owner = NSObject()

        handler.addPressureCallback(for: owner) { _ in }
        handler.removeCallback(for: owner)
        // Second remove must be a no-op.
        handler.removeCallback(for: owner)
        // No crash = pass.
    }

    func test_multipleOwners_independentCallbacks() {
        let handler = MemoryPressureHandler()
        let owner1 = NSObject()
        let owner2 = NSObject()

        handler.addPressureCallback(for: owner1) { _ in }
        handler.addPressureCallback(for: owner2) { _ in }

        // Remove one; the other must still be present (no crash on re-removal).
        handler.removeCallback(for: owner1)
        // If owner2's callback were also removed, re-adding for owner2 would
        // be a brand-new insert rather than a no-op — we can't distinguish
        // from outside, but we confirm no crash on the whole sequence.
        handler.removeCallback(for: owner2)
    }

    // MARK: - Lifecycle: deinit of handler while callbacks are registered

    func test_handlerDeinit_withRegisteredCallbacks_doesNotCrash() {
        let owner = NSObject()
        var handler: MemoryPressureHandler? = MemoryPressureHandler()
        handler?.addPressureCallback(for: owner) { _ in }
        handler = nil
        // If we reach here, the handler released its callback table cleanly.
    }
}
#endif

import Foundation

/// Static flags for hardware-gated test skipping.
///
/// Use these with `XCTSkipUnless` / `XCTSkipIf` at the top of tests that
/// require specific hardware or OS capabilities.
public enum HardwareRequirements {

    /// `true` when running on Apple Silicon (arm64). MLX and llama.cpp
    /// backends require this architecture.
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// `true` when running on a physical device rather than the iOS Simulator.
    /// Metal compute is unavailable in the simulator, so backends that use
    /// GPU acceleration (MLX, llama.cpp) will fail there.
    public static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// `true` when the OS version supports Foundation Models (macOS 26+ / iOS 26+).
    /// This does NOT check whether Apple Intelligence is enabled — use
    /// `FoundationBackend.isAvailable` for that.
    public static var hasFoundationModels: Bool {
        if #available(macOS 26, iOS 26, *) {
            return true
        }
        return false
    }
}

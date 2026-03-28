import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Model Size Recommendation

public enum ModelSizeRecommendation: String, CaseIterable, Sendable {
    case small
    case medium
    case large
    case xlarge

    /// Maximum model file size in bytes for this recommendation tier.
    public var maxModelBytes: UInt64 {
        switch self {
        case .small:  return 2_500_000_000   // ~2.5 GB (e.g., Phi-3 Mini Q4)
        case .medium: return 4_500_000_000   // ~4.5 GB (e.g., Mistral 7B Q4_K_M)
        case .large:  return 6_000_000_000   // ~6 GB   (e.g., Mistral 7B Q6_K)
        case .xlarge: return 40_000_000_000  // ~40 GB  (e.g., 70B Q4)
        }
    }

    /// Human-readable description of the tier and typical models.
    public var description: String {
        switch self {
        case .small:
            return "Small models up to 2.5 GB (e.g., Phi-3 Mini Q4)"
        case .medium:
            return "Medium models up to 4.5 GB (e.g., Mistral 7B Q4_K_M)"
        case .large:
            return "Large models up to 6 GB (e.g., Mistral 7B Q6_K)"
        case .xlarge:
            return "Extra-large models up to 40 GB (e.g., 70B Q4)"
        }
    }
}

// MARK: - Device Capability Service

/// Queries device hardware to determine which LLM models can safely run on this device.
///
/// Memory safety is critical on iOS -- the system kills apps that exceed memory limits.
/// This service provides conservative recommendations so the app stays well within bounds.
public final class DeviceCapabilityService: Sendable {

    /// Fraction of physical RAM we allow the model + KV cache to occupy.
    /// 70% leaves headroom for the OS, the app itself, and other background work.
    private static let maxMemoryFraction: Double = 0.70

    /// Total physical RAM on this device, in bytes.
    public let physicalMemory: UInt64

    // MARK: - Initialisation

    /// Creates a service using the real device's physical memory.
    public init() {
        self.physicalMemory = ProcessInfo.processInfo.physicalMemory
    }

    /// Creates a service with an explicit memory value (useful for unit tests).
    public init(physicalMemory: UInt64) {
        self.physicalMemory = physicalMemory
    }

    // MARK: - Public API

    /// Returns `true` if the device has enough RAM to load a model of the given size.
    ///
    /// The check accounts for both the model weights and an estimated KV cache overhead
    /// (roughly 20% on top of the model file size for context-window buffers).
    ///
    /// - Parameter estimatedMemoryBytes: The on-disk size of the GGUF model file.
    ///   Runtime memory usage is somewhat larger due to KV cache and working buffers.
    public func canLoadModel(estimatedMemoryBytes: UInt64) -> Bool {
        let kvCacheOverhead = Double(estimatedMemoryBytes) * 0.20
        let totalRequired = Double(estimatedMemoryBytes) + kvCacheOverhead
        let availableBudget = Double(physicalMemory) * Self.maxMemoryFraction
        return totalRequired <= availableBudget
    }

    /// Recommends the largest model tier this device can comfortably run.
    public func recommendedModelSize() -> ModelSizeRecommendation {
        let ramGB = physicalMemory / (1024 * 1024 * 1024)

        switch ramGB {
        case 0...6:
            return .small
        case 7...8:
            return .medium
        case 9...16:
            return .large
        default:
            return .xlarge
        }
    }

    /// A human-readable description of the current device and its RAM.
    public var deviceDescription: String {
        let ramGB = physicalMemory / (1024 * 1024 * 1024)
        let deviceName = platformDeviceName
        return "\(deviceName) with \(ramGB) GB RAM"
    }

    // MARK: - Private Helpers

    private var platformDeviceName: String {
        #if os(iOS)
        return UIDevice.current.model  // e.g., "iPad", "iPhone"
        #elseif os(macOS)
        return macModelName
        #else
        return "Unknown Device"
        #endif
    }

    #if os(macOS)
    /// Reads the Mac's marketing model name via `sysctl hw.model`, falling back to a generic label.
    private var macModelName: String {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }

        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let identifier = String(cString: model)

        // The sysctl value is a hardware identifier like "Mac14,6".
        // A full marketing-name lookup would require IOKit; keeping it simple for now.
        if identifier.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if identifier.hasPrefix("MacBookAir") { return "MacBook Air" }
        if identifier.hasPrefix("Macmini")    { return "Mac mini" }
        if identifier.hasPrefix("MacPro")     { return "Mac Pro" }
        if identifier.hasPrefix("iMac")       { return "iMac" }
        if identifier.hasPrefix("Mac")        { return "Mac" }
        return identifier
    }
    #endif
}

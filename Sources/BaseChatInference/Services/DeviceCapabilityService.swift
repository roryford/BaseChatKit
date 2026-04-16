import Foundation
import MachO

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

    /// Fraction of available memory to reserve for model weights and runtime overhead.
    /// 40% headroom leaves 60% for the KV cache allocation.
    ///
    /// This is intentionally conservative: the KV cache for a 128K context at 8 KB/token
    /// is ~1 GB, and model weights easily occupy 2–5 GB. On iPad the per-app jetsam limit
    /// is a fraction of physical RAM, so we must budget from available memory, not physical.
    private static let kvHeadroomFraction: Double = 0.40

    /// Conservative KV-cache cost per context token in bytes.
    ///
    /// Derived from llama.cpp's own estimate: 2 KV elements per layer at 4 bytes each
    /// (fp16), multiplied by ~32 transformer layers for a typical 7B model ≈ 256 KB/token.
    /// Rounding up to 8 KB/token accounts for additional working buffers and variance
    /// across model architectures. This matches the constant used in `LlamaBackend`.
    private static let kvBytesPerToken: UInt64 = 8_192

    /// Absolute maximum context tokens we will ever request, regardless of model or device.
    private static let absoluteContextCeiling: Int = 128_000

    /// Fallback default context size when the model's trained length is unknown.
    private static let unknownContextDefault: Int = 8_192

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

    /// Computes a safe GGUF context size for this device, clamped to both the model's
    /// trained context length and a memory-derived ceiling.
    ///
    /// On iOS, available memory is read from `os_proc_available_memory()` — the per-app
    /// jetsam budget — rather than physical RAM, which is meaningless as a per-app limit.
    /// On macOS the jetsam budget does not exist, so physical memory is used (consistent
    /// with the existing LlamaBackend behaviour on that platform).
    ///
    /// - Parameters:
    ///   - detectedContextLength: The model's trained context length, if known from GGUF metadata.
    ///     Pass `nil` when unknown — the method falls back to `unknownContextDefault` (8 192).
    ///   - availableMemoryBytes: Available memory in bytes. When `nil`, the method queries
    ///     the system itself — useful for injection in tests.
    /// - Returns: A safe `Int32` context token count.
    public static func safeContextSize(
        for detectedContextLength: Int?,
        availableMemoryBytes: UInt64? = nil
    ) -> Int32 {
        let available = availableMemoryBytes ?? Self.queryAvailableMemory()

        // Reserve 40% for model weights + runtime; KV cache gets the rest.
        let kvBudgetBytes = UInt64(Double(available) * (1.0 - kvHeadroomFraction))

        // Derive token ceiling: kvBudgetBytes / 8 KB per token.
        let memoryCeiling = Int(kvBudgetBytes / kvBytesPerToken)

        // Clamp to the model's trained length (never exceed what it was designed for).
        let trainedCeiling = detectedContextLength ?? unknownContextDefault

        let result = min(memoryCeiling, trainedCeiling, absoluteContextCeiling)

        // Floor at 1 to avoid passing a nonsensical value to llama.cpp, even in
        // pathological low-memory scenarios where available memory is near zero.
        return Int32(max(1, result))
    }

    /// Returns the number of bytes available for allocation by this process.
    ///
    /// On iOS/tvOS/watchOS, `os_proc_available_memory()` returns the per-app jetsam budget.
    /// On macOS, physical memory is used as an upper bound (macOS has no per-app jetsam limit).
    public static func queryAvailableMemory() -> UInt64 {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let available = os_proc_available_memory()
        // os_proc_available_memory() can return 0 or a negative value in edge cases
        // (e.g., during simulator startup); fall back to physical memory in that case.
        if available > 0 {
            return UInt64(available)
        }
        return ProcessInfo.processInfo.physicalMemory
        #else
        return ProcessInfo.processInfo.physicalMemory
        #endif
    }

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
        return iOSDeviceName
        #elseif os(macOS)
        return macModelName
        #else
        return "Unknown Device"
        #endif
    }

    #if os(iOS)
    /// Reads the iOS device machine identifier via `sysctl hw.machine` (e.g., "iPhone16,2").
    /// UIDevice is unavailable in Swift 6 strict concurrency; sysctl works on any thread.
    private var iOSDeviceName: String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "iPhone" }

        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let identifier = String(decoding: machine.map(UInt8.init(bitPattern:)), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)

        // Map hardware identifier prefix to human-readable family.
        if identifier.hasPrefix("iPad")    { return "iPad" }
        if identifier.hasPrefix("iPhone")  { return "iPhone" }
        if identifier.hasPrefix("AppleTV") { return "Apple TV" }
        return identifier
    }
    #endif

    #if os(macOS)
    /// Reads the Mac's marketing model name via `sysctl hw.model`, falling back to a generic label.
    private var macModelName: String {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }

        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let identifier = String(decoding: model.map(UInt8.init(bitPattern:)), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)

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

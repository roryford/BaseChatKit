import Foundation
import MachO

/// Pre-flight memory check before loading a model.
///
/// Estimates whether the device has enough available memory to load a model
/// based on the backend's memory strategy and the model's file size.
public struct MemoryGate: Sendable {

    /// Closure that returns the available memory budget in bytes.
    /// Injectable for testing.
    public let availableMemoryBytes: @Sendable () -> UInt64

    /// Total physical memory, for heuristic fallback.
    public let physicalMemoryBytes: UInt64

    /// Controls whether a deny verdict throws an error or just logs a warning.
    public let denyBehavior: DenyBehavior

    public enum DenyBehavior: Sendable, Equatable {
        case throwError
        case warnOnly
    }

    public init(
        availableMemoryBytes: @escaping @Sendable () -> UInt64,
        physicalMemoryBytes: UInt64,
        denyBehavior: DenyBehavior = .warnOnly
    ) {
        self.availableMemoryBytes = availableMemoryBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.denyBehavior = denyBehavior
    }

    /// Creates a gate using real system values.
    public init() {
        let physical = ProcessInfo.processInfo.physicalMemory
        self.physicalMemoryBytes = physical
        self.availableMemoryBytes = { Self.systemAvailableMemory(physicalMemoryBytes: physical) }
        #if os(iOS)
        self.denyBehavior = .throwError
        #else
        self.denyBehavior = .warnOnly
        #endif
    }

    /// Result of a pre-load memory check.
    public enum Verdict: Sendable, Equatable {
        /// Safe to proceed.
        case allow
        /// Possible but risky -- model may cause swapping or pressure.
        case warn(estimatedBytes: UInt64, availableBytes: UInt64)
        /// Insufficient memory -- loading will likely crash (iOS) or severely degrade (macOS).
        case deny(estimatedBytes: UInt64, availableBytes: UInt64)
    }

    /// Checks whether a model of the given file size can be loaded with the given memory strategy.
    public func check(
        modelFileSize: UInt64,
        strategy: MemoryStrategy
    ) -> Verdict {
        switch strategy {
        case .external:
            return .allow

        case .mappable:
            // Only KV cache + working buffers need RAM.
            let estimated = UInt64(Double(modelFileSize) * 0.25)
            return evaluate(estimatedBytes: estimated)

        case .resident:
            // Full model + ~20% KV cache overhead must fit.
            let estimated = UInt64(Double(modelFileSize) * 1.20)
            return evaluate(estimatedBytes: estimated)
        }
    }

    private func evaluate(estimatedBytes: UInt64) -> Verdict {
        let available = availableMemoryBytes()

        // Plenty of headroom.
        if estimatedBytes <= UInt64(Double(available) * 0.85) {
            return .allow
        }

        // Tight but might fit.
        if estimatedBytes <= available {
            return .warn(estimatedBytes: estimatedBytes, availableBytes: available)
        }

        // Won't fit.
        return .deny(estimatedBytes: estimatedBytes, availableBytes: available)
    }

    // MARK: - System Memory Query

    /// Returns an estimate of available memory in bytes.
    ///
    /// On iOS, uses `os_proc_available_memory()` which returns the number of bytes
    /// the app can allocate before the system starts killing processes.
    /// On macOS, uses Mach VM statistics (free + inactive pages) as a heuristic.
    private static func systemAvailableMemory(physicalMemoryBytes: UInt64) -> UInt64 {
        #if os(iOS) || os(tvOS) || os(watchOS)
        return UInt64(os_proc_available_memory())
        #else
        return macAvailableMemory(physicalMemoryFallback: physicalMemoryBytes)
        #endif
    }

    #if os(macOS)
    private static func macAvailableMemory(physicalMemoryFallback: UInt64) -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            // Fallback: estimate 60% of physical memory.
            return UInt64(Double(physicalMemoryFallback) * 0.60)
        }
        // Read the host page size directly via Mach instead of using `vm_page_size`.
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageSizeU64 = UInt64(pageSize)
        // Free + inactive pages are reclaimable without swapping.
        let available = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSizeU64
        return available
    }
    #endif
}

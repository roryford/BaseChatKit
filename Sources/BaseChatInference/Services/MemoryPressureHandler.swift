import Foundation
import Observation

// MARK: - Memory Pressure Level

public enum MemoryPressureLevel: String, Sendable {
    /// System memory is comfortable. Normal operation.
    case nominal
    /// System memory is getting tight. Pause heavy work (e.g., token generation).
    case warning
    /// System memory is critically low. Unload the model to avoid being killed.
    case critical
}

// MARK: - Memory Pressure Handler

/// Monitors OS-level memory pressure and exposes the current level so ViewModels
/// can react (pause generation on `.warning`, unload the model on `.critical`).
///
/// Uses `DispatchSource.makeMemoryPressureSource`, which works identically on iOS and macOS.
@Observable
package final class MemoryPressureHandler: @unchecked Sendable {

    // MARK: - Published State

    /// The current memory pressure level reported by the OS.
    package internal(set) var pressureLevel: MemoryPressureLevel = .nominal

    // MARK: - Private State

    /// The GCD memory-pressure dispatch source. Retained while monitoring is active.
    private var source: DispatchSourceMemoryPressure?

    /// Serial queue for processing memory pressure events.
    private let queue = DispatchQueue(
        label: BaseChatConfiguration.shared.memoryPressureQueueLabel,
        qos: .utility
    )

    // MARK: - Lifecycle

    package init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Public API

    /// Begins listening for memory pressure notifications from the OS.
    ///
    /// Safe to call multiple times -- subsequent calls are no-ops while monitoring is active.
    package func startMonitoring() {
        guard source == nil else { return }

        let newSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = newSource.data

            // DispatchSource.MemoryPressureEvent is an OptionSet.
            // Map it to our simpler enum.
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .nominal
            }

            // Update on main actor so SwiftUI observation triggers correctly.
            Task { @MainActor in
                self.pressureLevel = level
            }
        }

        newSource.setCancelHandler { [weak self] in
            // Ensure we nil out the source on cancellation to allow re-start.
            // Weak capture in the Task prevents sending self across isolation boundaries.
            Task { @MainActor [weak self] in
                self?.source = nil
            }
        }

        source = newSource
        newSource.activate()
    }

    /// Stops listening for memory pressure notifications.
    ///
    /// Safe to call multiple times -- subsequent calls are no-ops if not monitoring.
    package func stopMonitoring() {
        source?.cancel()
        source = nil
    }
}

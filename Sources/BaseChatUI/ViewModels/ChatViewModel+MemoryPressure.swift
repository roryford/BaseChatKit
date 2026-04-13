import Foundation
import BaseChatCore
import BaseChatInference

// MARK: - ChatViewModel + Memory Pressure

extension ChatViewModel {

    public func startMemoryMonitoring() {
        memoryPressure.startMonitoring()
    }

    public func stopMemoryMonitoring() {
        memoryPressure.stopMonitoring()
    }

    public func handleMemoryPressure() {
        let level = memoryPressure.pressureLevel
        guard level != lastPressureLevel else { return }
        lastPressureLevel = level

        switch level {
        case .critical:
            stopGeneration()
            unloadModel()
            activeError = ChatError(kind: .memoryPressure, message: "Memory pressure is critical. The model was unloaded to prevent the app from being terminated.", recovery: .dismissOnly)
        case .warning:
            activeError = ChatError(kind: .memoryPressure, message: "Memory pressure is elevated. Consider closing other apps.", recovery: .dismissOnly)
        case .nominal:
            if activeError?.kind == .memoryPressure {
                activeError = nil
            }
        }
    }
}

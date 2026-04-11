import BaseChatInference

// Source-compatibility shims so callers can pass an @Model `ChatSession` to the
// `SettingsService` resolution helpers, even though those helpers now operate
// on the storage-agnostic `ChatSessionRecord` after the BaseChatInference split.
extension SettingsService {

    /// Returns the effective temperature, using session override if available.
    @MainActor
    public func effectiveTemperature(session: ChatSession?) -> Float {
        session?.temperature ?? globalTemperature ?? 0.7
    }

    @MainActor
    public func effectiveTopP(session: ChatSession?) -> Float {
        session?.topP ?? globalTopP ?? 0.9
    }

    @MainActor
    public func effectiveRepeatPenalty(session: ChatSession?) -> Float {
        session?.repeatPenalty ?? globalRepeatPenalty ?? 1.1
    }
}

import SwiftData

/// Convenience type that vends all BaseChatCore SwiftData model types for
/// use in `ModelContainer` setup.
///
/// ```swift
/// let container = try ModelContainer(
///     for: Schema(BaseChatSchema.allModelTypes),
///     configurations: ModelConfiguration(isStoredInMemoryOnly: false)
/// )
/// ```
public enum BaseChatSchema {
    public static let allModelTypes: [any PersistentModel.Type] = [
        ChatMessage.self,
        ChatSession.self,
        SamplerPreset.self,
        APIEndpoint.self,
    ]
}

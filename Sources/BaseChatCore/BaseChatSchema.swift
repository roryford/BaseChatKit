import SwiftData

/// Convenience type that vends all BaseChatCore SwiftData model types for
/// use in `ModelContainer` setup.
///
/// > Deprecated: Use ``ModelContainerFactory/makeInMemoryContainer()`` or
/// > ``ModelContainerFactory/makeContainer(configurations:)`` instead, which
/// > supply the versioned schema and migration plan required by SwiftData.
public enum BaseChatSchema {
    @available(*, deprecated, renamed: "ModelContainerFactory.makeInMemoryContainer")
    public static let allModelTypes: [any PersistentModel.Type] = [
        BaseChatSchemaV1.ChatMessage.self,
        BaseChatSchemaV1.ChatSession.self,
        BaseChatSchemaV1.SamplerPreset.self,
        BaseChatSchemaV1.APIEndpoint.self,
    ]
}

import Foundation
import SwiftData

/// A chat session containing a sequence of messages with its own settings.
///
/// The concrete type is the frozen snapshot defined in `BaseChatSchemaV1`.
/// Update this typealias when a new schema version changes this model.
public typealias ChatSession = BaseChatSchemaV1.ChatSession

import Foundation
import SwiftData

/// A saved set of generation parameters that can be applied to any session.
///
/// The concrete type is the frozen snapshot defined in `BaseChatSchemaV1`.
/// Update this typealias when a new schema version changes this model.
public typealias SamplerPreset = BaseChatSchemaV1.SamplerPreset

import Foundation
import SwiftData

/// A saved set of generation parameters that can be applied to any session.
@Model
public final class SamplerPreset {
    public var id: UUID
    public var name: String
    public var temperature: Float
    public var topP: Float
    public var repeatPenalty: Float
    public var createdAt: Date

    public init(name: String, temperature: Float = 0.7, topP: Float = 0.9, repeatPenalty: Float = 1.1) {
        self.id = UUID()
        self.name = name
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.createdAt = Date()
    }
}

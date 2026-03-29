import Foundation

public struct CompressibleMessage: Sendable {
    public let id: UUID
    public let role: String        // "user" | "assistant" | "system"
    public let content: String
    public let isPinned: Bool

    public init(id: UUID, role: String, content: String, isPinned: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isPinned = isPinned
    }
}

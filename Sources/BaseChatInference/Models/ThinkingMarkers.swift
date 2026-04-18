public struct ThinkingMarkers: Sendable, Equatable {
    public let open: String
    public let close: String

    /// Bytes to hold back at chunk boundary — prevents partial-tag emission.
    public var holdback: Int { max(open.count, close.count) }

    public init(open: String, close: String) {
        self.open = open
        self.close = close
    }

    /// Qwen3 and DeepSeek-R1 inline thinking tags.
    public static let qwen3 = ThinkingMarkers(open: "<think>", close: "</think>")

    /// Extensibility hook for custom model formats.
    public static func custom(open: String, close: String) -> ThinkingMarkers {
        ThinkingMarkers(open: open, close: close)
    }
}

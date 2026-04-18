/// Stateful, chunk-safe parser that separates reasoning from visible text.
///
/// Emits `[GenerationEvent]` from each chunk rather than a plain `String`,
/// allowing callers to route thinking content separately from visible content.
/// Parameterized by `ThinkingMarkers` so the same logic handles both
/// `<think>`/`</think>` (Qwen3, DeepSeek-R1) and custom model formats.
public struct ThinkingParser {
    public let markers: ThinkingMarkers
    private var depth = 0
    private var buffer = ""

    public init(markers: ThinkingMarkers = .qwen3) {
        self.markers = markers
    }

    /// Process a chunk of streamed text. Returns a mix of `.token`,
    /// `.thinkingToken`, and `.thinkingComplete` events.
    public mutating func process(_ chunk: String) -> [GenerationEvent] {
        buffer += chunk
        var events: [GenerationEvent] = []

        while true {
            let tag = depth > 0 ? markers.close : markers.open

            if let range = buffer.range(of: tag) {
                // Emit everything before the tag as the current mode's event type
                let before = String(buffer[..<range.lowerBound])
                if !before.isEmpty {
                    events.append(depth > 0 ? .thinkingToken(before) : .token(before))
                }

                // Transition state
                if depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        // Only fire thinkingComplete on 1→0 transition (not for nested close tags)
                        events.append(.thinkingComplete)
                    }
                } else {
                    depth += 1
                }

                buffer = String(buffer[range.upperBound...])
            } else {
                break
            }
        }

        // Hold back bytes that could be the start of a partial open or close tag.
        // Size = max(open.count, close.count) to handle either partial tag.
        let holdback = markers.holdback
        if buffer.count > holdback {
            let safeCount = buffer.count - holdback
            let confirmed = String(buffer.prefix(safeCount))
            buffer = String(buffer.suffix(holdback))
            if !confirmed.isEmpty {
                events.append(depth > 0 ? .thinkingToken(confirmed) : .token(confirmed))
            }
        }

        return events
    }

    /// Flush the held-back buffer at stream end. Call once after the generation loop ends.
    /// Returns `.thinkingToken` if inside an unclosed block, `.token` otherwise.
    public mutating func finalize() -> [GenerationEvent] {
        guard !buffer.isEmpty else { return [] }
        let remaining = buffer
        buffer = ""
        return [depth > 0 ? .thinkingToken(remaining) : .token(remaining)]
    }
}

@available(*, deprecated, renamed: "ThinkingParser",
    message: "Return type changed from String to [GenerationEvent]. Use ThinkingParser directly.")
public typealias ThinkingBlockFilter = ThinkingParser

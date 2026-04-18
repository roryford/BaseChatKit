/// Stateful, chunk-safe filter that strips `<think>...</think>` reasoning blocks
/// from streamed token output.
///
/// Tokens arrive as arbitrary-length strings that may split a tag across boundaries.
/// The filter buffers incomplete tag prefixes until enough characters arrive to
/// confirm or reject a match.
public struct ThinkingBlockFilter {
    private var depth = 0
    private var buffer = ""

    public init() {}

    /// Process one token chunk. Returns the visible portion (may be empty).
    public mutating func process(_ chunk: String) -> String {
        buffer += chunk
        return flush()
    }

    private mutating func flush() -> String {
        var output = ""

        while !buffer.isEmpty {
            if depth == 0 {
                // Visible mode: emit text up to the next '<'
                if let angleIdx = buffer.firstIndex(of: "<") {
                    // Emit everything before the '<'
                    output += buffer[buffer.startIndex..<angleIdx]
                    buffer = String(buffer[angleIdx...])

                    // Now buffer starts with '<'; check for tag or partial
                    if buffer.hasPrefix("<think>") {
                        depth += 1
                        buffer = String(buffer.dropFirst("<think>".count))
                    } else if buffer.hasPrefix("</think>") {
                        // Mismatched close tag in visible mode — swallow it
                        // (depth can't go negative, so treat as visible but consume the tag)
                        buffer = String(buffer.dropFirst("</think>".count))
                    } else if "<think>".hasPrefix(buffer) || "</think>".hasPrefix(buffer) {
                        // Partial prefix — wait for more input
                        break
                    } else {
                        // Not a think-related tag; emit the '<' and continue
                        output += "<"
                        buffer = String(buffer.dropFirst())
                    }
                } else {
                    // No '<' in buffer — all visible
                    output += buffer
                    buffer = ""
                }
            } else {
                // Suppressed mode: skip everything, only look for tag boundaries
                if let angleIdx = buffer.firstIndex(of: "<") {
                    // Discard text before '<'
                    buffer = String(buffer[angleIdx...])

                    if buffer.hasPrefix("<think>") {
                        depth += 1
                        buffer = String(buffer.dropFirst("<think>".count))
                    } else if buffer.hasPrefix("</think>") {
                        depth = max(0, depth - 1)
                        buffer = String(buffer.dropFirst("</think>".count))
                    } else if "<think>".hasPrefix(buffer) || "</think>".hasPrefix(buffer) {
                        // Partial prefix — wait for more input
                        break
                    } else {
                        // Non-think '<' inside a thinking block — swallow it
                        buffer = String(buffer.dropFirst())
                    }
                } else {
                    // No '<' — all suppressed, discard
                    buffer = ""
                }
            }
        }

        return output
    }
}

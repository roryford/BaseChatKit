#if Llama
import Foundation
import BaseChatInference

/// Stateful, chunk-safe parser that extracts tool calls from Gemma 4 GGUF
/// token streams produced by `LlamaGenerationDriver`.
///
/// ## Token format
///
/// Gemma 4 IT GGUF models emit tool invocations using special tokens:
///
/// ```
/// <|tool_call>
/// call:function_name{param1:<|"|>value<|"|>}
/// <|end_of_turn>
/// ```
///
/// `<|"|>` is Gemma 4's string-quoting special token; it is substituted with
/// `"` before the call body is interpreted as a JSON-like object.
///
/// ## Fallback format
///
/// For tool-calling fine-tunes that deviate from the Gemma 4 native format
/// and instead emit a JSON object between `<tool_call>` / `</tool_call>` tags
/// (as used by Qwen and other models), the parser also accepts:
///
/// ```
/// <tool_call>
/// {"name": "function_name", "arguments": {"param": "value"}}
/// </tool_call>
/// ```
///
/// ## Chunk safety
///
/// Tags that straddle chunk boundaries are held back until the boundary is
/// resolved, using the same prefix-hold strategy as `MLXToolCallParser` and
/// `ThinkingParser`.
///
/// ## Usage
///
/// ```swift
/// var parser = LlamaToolCallParser()
/// for chunk in tokenStream {
///     for event in parser.process(chunk) { … }
/// }
/// for event in parser.finalize() { … }
/// ```
struct LlamaToolCallParser: Sendable {

    // MARK: - Tag constants

    /// Gemma 4 native open token.
    static let gemma4OpenTag = "<|tool_call>"
    /// Gemma 4 turn-end token used to close a native tool call.
    static let gemma4EndTurn = "<|end_of_turn>"
    /// Gemma 4 string-quoting token substituted with `"` before parsing.
    static let gemma4QuoteToken = "<|\"|>"

    /// Standard JSON open tag (fallback for non-native tool-call fine-tunes).
    static let jsonOpenTag  = "<tool_call>"
    /// Standard JSON close tag.
    static let jsonCloseTag = "</tool_call>"

    // MARK: - State

    private var buffer = ""
    private var insideToolCall = false
    private var callBuffer = ""
    /// `true` when the open tag was the Gemma 4 native `<|tool_call>` form.
    private var usingGemma4Format = false

    // MARK: - Processing

    /// Process a chunk of streamed text.
    ///
    /// - Parameter chunk: Raw token text as emitted by the generation loop.
    /// - Returns: A (possibly empty) array of ``GenerationEvent`` values.
    ///   Text outside tool-call delimiters is emitted as `.token` events;
    ///   a complete call produces a `.toolCall` event.
    mutating func process(_ chunk: String) -> [GenerationEvent] {
        buffer += chunk
        var events: [GenerationEvent] = []

        while true {
            if insideToolCall {
                let closeTag = usingGemma4Format ? Self.gemma4EndTurn : Self.jsonCloseTag
                if let range = buffer.range(of: closeTag) {
                    callBuffer += String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    if let event = parseCallBuffer(callBuffer) {
                        events.append(event)
                    }
                    callBuffer = ""
                    insideToolCall = false
                } else {
                    // Hold back partial close-tag suffix.
                    let maxHold = min(buffer.count, closeTag.count - 1)
                    var holdLen = 0
                    for l in stride(from: maxHold, through: 1, by: -1) {
                        if closeTag.hasPrefix(String(buffer.suffix(l))) {
                            holdLen = l
                            break
                        }
                    }
                    if buffer.count > holdLen {
                        callBuffer += String(buffer.prefix(buffer.count - holdLen))
                        buffer = holdLen > 0 ? String(buffer.suffix(holdLen)) : ""
                    }
                    break
                }
            } else {
                // Find the earliest of the two open-tag candidates.
                let g4Range   = buffer.range(of: Self.gemma4OpenTag)
                let jsonRange = buffer.range(of: Self.jsonOpenTag)

                let (chosenRange, isGemma4): (Range<String.Index>?, Bool)
                switch (g4Range, jsonRange) {
                case let (g4?, json?) where g4.lowerBound <= json.lowerBound:
                    (chosenRange, isGemma4) = (g4, true)
                case let (g4?, json?) where g4.lowerBound > json.lowerBound:
                    (chosenRange, isGemma4) = (json, false)
                case (let g4?, nil):
                    (chosenRange, isGemma4) = (g4, true)
                case (nil, let json?):
                    (chosenRange, isGemma4) = (json, false)
                default:
                    (chosenRange, isGemma4) = (nil, false)
                }

                if let range = chosenRange {
                    let before = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    if !before.isEmpty {
                        events.append(.token(before))
                    }
                    insideToolCall = true
                    usingGemma4Format = isGemma4
                } else {
                    break
                }
            }
        }

        // Hold back partial open-tag suffix when not inside a call.
        if !insideToolCall {
            let candidates = [Self.gemma4OpenTag, Self.jsonOpenTag]
            let maxTagLen  = candidates.map(\.count).max()! - 1
            let maxCheck   = min(buffer.count, maxTagLen)
            var holdLen    = 0
            for candidate in candidates {
                for l in stride(from: maxCheck, through: 1, by: -1) {
                    if candidate.hasPrefix(String(buffer.suffix(l))) {
                        holdLen = max(holdLen, l)
                    }
                }
            }
            if buffer.count > holdLen {
                let confirmed = String(buffer.prefix(buffer.count - holdLen))
                buffer = holdLen > 0 ? String(buffer.suffix(holdLen)) : ""
                if !confirmed.isEmpty {
                    events.append(.token(confirmed))
                }
            }
        }

        return events
    }

    /// Flush the held-back buffer at stream end.
    ///
    /// Call once after the generation loop finishes to emit any remaining
    /// visible text. An incomplete (unclosed) tool-call block is discarded —
    /// partial JSON cannot produce a valid `ToolCall`.
    mutating func finalize() -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        if !insideToolCall && !buffer.isEmpty {
            events.append(.token(buffer))
        }
        buffer = ""
        callBuffer = ""
        insideToolCall = false
        return events
    }

    // MARK: - Call body parsing

    private func parseCallBuffer(_ raw: String) -> GenerationEvent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("call:") {
            return parseGemma4NativeCall(trimmed)
        }
        return parseJSONCall(trimmed)
    }

    /// Parses Gemma 4 native format: `call:name{param1:<|"|>val<|"|>}`.
    ///
    /// `<|"|>` is Gemma 4's string-quoting special token and is substituted
    /// with `"` before the brace-delimited body is parsed as JSON.
    private func parseGemma4NativeCall(_ raw: String) -> GenerationEvent? {
        let body = String(raw.dropFirst("call:".count))
        let substituted = body.replacingOccurrences(of: Self.gemma4QuoteToken, with: "\"")

        guard let braceIndex = substituted.firstIndex(of: "{") else { return nil }
        let name = String(substituted[..<braceIndex]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let jsonBody = String(substituted[braceIndex...])
        let argsString = canonicalizedArguments(from: jsonBody) ?? "{}"
        let id = "llama-\(name)-\(UUID().uuidString.prefix(8))"
        return .toolCall(ToolCall(id: id, toolName: name, arguments: argsString))
    }

    /// Parses JSON fallback format: `{"name":"...","arguments":{...}}`.
    private func parseJSONCall(_ json: String) -> GenerationEvent? {
        guard let data = json.data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty
        else { return nil }

        let argsString: String
        if let argsDict = obj["arguments"] as? [String: Any],
           let serialized = try? JSONSerialization.data(withJSONObject: argsDict),
           let str = String(data: serialized, encoding: .utf8) {
            argsString = str
        } else if let rawStr = obj["arguments"] as? String {
            argsString = rawStr
        } else {
            argsString = "{}"
        }

        let id = "llama-\(name)-\(UUID().uuidString.prefix(8))"
        return .toolCall(ToolCall(id: id, toolName: name, arguments: argsString))
    }

    /// Round-trips `jsonBody` through `JSONSerialization` to canonicalize it.
    /// Returns `nil` on parse failure; callers fall back to `"{}"`.
    private func canonicalizedArguments(from jsonBody: String) -> String? {
        guard let data = jsonBody.data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let serialized = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: serialized, encoding: .utf8)
        else { return nil }
        return str
    }
}
#endif

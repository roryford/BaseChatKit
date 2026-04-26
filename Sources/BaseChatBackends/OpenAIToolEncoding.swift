#if CloudSaaS
import Foundation
import os
import BaseChatInference

/// Helpers shared by ``OpenAIBackend`` (Chat Completions) and
/// ``OpenAIResponsesBackend`` (Responses API) for encoding the BCK
/// ``ToolDefinition`` / ``ToolChoice`` / ``ToolAwareHistoryEntry`` types into
/// OpenAI's wire format.
///
/// Chat Completions and the Responses API use the same `tools[]` envelope —
/// `{type: "function", function: {name, description, parameters}}` — and the
/// same `tool_choice` shape, so a single set of encoders covers both.
/// Tool-result feedback differs slightly between the two APIs:
///
/// - Chat Completions: `{role: "tool", tool_call_id, content}` plus an
///   assistant turn carrying `tool_calls[]`.
/// - Responses: `{type: "function_call_output", call_id, output}` plus
///   `{type: "function_call", call_id, name, arguments}` items.
///
/// The encoder for the assistant + tool turns is therefore split across two
/// helpers (`encodeChatCompletionsHistory`, `encodeResponsesInput`).
enum OpenAIToolEncoding {

    // MARK: - Tool definitions

    /// Encodes a ``ToolDefinition`` into the `{type:"function", function:{...}}`
    /// envelope used by both Chat Completions and Responses.
    static func encodeToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
        var function: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let parameters = foundationJSON(from: tool.parameters) {
            function["parameters"] = parameters
        } else {
            function["parameters"] = ["type": "object", "properties": [String: Any]()]
        }
        return [
            "type": "function",
            "function": function,
        ]
    }

    // MARK: - tool_choice

    /// Applies ``GenerationConfig/toolChoice`` to a request body in the OpenAI
    /// shape. `auto` omits the field entirely (server default); `.none` /
    /// `.required` are passed as literal strings; `.tool(name:)` produces the
    /// nested function-selection object.
    static func applyToolChoice(_ choice: ToolChoice, into body: inout [String: Any]) {
        switch choice {
        case .auto:
            break
        case .none:
            body["tool_choice"] = "none"
        case .required:
            body["tool_choice"] = "required"
        case .tool(let name):
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": name],
            ]
        }
    }

    // MARK: - History encoding (Chat Completions)

    /// Encodes a ``ToolAwareHistoryEntry`` for the Chat Completions
    /// `messages[]` array.
    ///
    /// Assistant turns with `toolCalls` get an OpenAI-shaped `tool_calls` array;
    /// tool-role turns get `tool_call_id`. Plain turns collapse to the same
    /// `{role, content}` shape.
    static func encodeChatCompletionsEntry(_ entry: ToolAwareHistoryEntry) -> [String: Any] {
        var obj: [String: Any] = [
            "role": entry.role,
            "content": entry.content,
        ]
        if let calls = entry.toolCalls, !calls.isEmpty {
            obj["tool_calls"] = calls.map(encodeToolCall)
        }
        if let callId = entry.toolCallId {
            obj["tool_call_id"] = callId
        }
        return obj
    }

    /// Encodes a ``ToolCall`` in the `tool_calls[]` shape used by the
    /// Chat Completions API:
    ///
    /// ```json
    /// {"id":"...","type":"function","function":{"name":"...","arguments":"..."}}
    /// ```
    ///
    /// Per the OpenAI spec, `arguments` is a stringified JSON blob (not a
    /// pre-parsed object) on Chat Completions. We pass the stored JSON string
    /// through as-is.
    static func encodeToolCall(_ call: ToolCall) -> [String: Any] {
        return [
            "id": call.id,
            "type": "function",
            "function": [
                "name": call.toolName,
                "arguments": call.arguments,
            ] as [String: Any],
        ]
    }

    // MARK: - History encoding (Responses API)

    /// Encodes a ``ToolAwareHistoryEntry`` for the Responses API `input[]`.
    ///
    /// The Responses API expresses tool turns with separate item types — an
    /// assistant turn with `tool_calls` becomes a `function_call` item per
    /// call, and a tool-role turn becomes a `function_call_output` item.
    /// Returns one or more items per entry.
    static func encodeResponsesEntries(_ entry: ToolAwareHistoryEntry) -> [[String: Any]] {
        // Tool-role entry → function_call_output.
        if entry.role == "tool", let callId = entry.toolCallId {
            return [[
                "type": "function_call_output",
                "call_id": callId,
                "output": entry.content,
            ]]
        }

        // Assistant entry with tool_calls → one function_call item per call,
        // plus an optional preamble message if there's any visible content.
        if entry.role == "assistant", let calls = entry.toolCalls, !calls.isEmpty {
            var items: [[String: Any]] = []
            if !entry.content.isEmpty {
                items.append([
                    "role": "assistant",
                    "content": entry.content,
                ])
            }
            for call in calls {
                items.append([
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.toolName,
                    "arguments": call.arguments,
                ])
            }
            return items
        }

        // Plain message turn.
        return [[
            "role": entry.role,
            "content": entry.content,
        ]]
    }

    // MARK: - JSONSchemaValue → Foundation primitives

    /// Encodes a ``JSONSchemaValue`` into the primitive graph
    /// `JSONSerialization` accepts. Returns `nil` if encoding fails — callers
    /// substitute a conservative empty-object default.
    static func foundationJSON(from value: JSONSchemaValue) -> Any? {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            Log.inference.warning(
                "OpenAIToolEncoding: failed to encode JSONSchemaValue for tools payload — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            Log.inference.warning(
                "OpenAIToolEncoding: failed to re-parse encoded schema for tools payload — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - Streaming tool-call accumulator

/// Buffers tool-call deltas indexed by `index` (Chat Completions) or by
/// `item_id`→`call_id` mapping (Responses) so the backend can emit
/// `.toolCallStart` once, stream `.toolCallArgumentsDelta` events, and fire
/// `.toolCall` only when the entry is finalized.
///
/// Compat servers (Together, Groq) sometimes drop `id` after the first delta
/// for a given index — the accumulator keys on integer index so subsequent
/// argument fragments still land in the right slot. The first non-empty `id`
/// observed for a given index is sticky.
final class StreamingToolCallAccumulator {

    struct Entry {
        var id: String
        var name: String
        var arguments: String
        /// Whether `.toolCallStart` has already been emitted for this entry.
        var started: Bool
    }

    /// Tracks entries in insertion order so `.toolCall` events can be
    /// emitted in the same order the model produced them, regardless of
    /// arrival interleaving. Keyed by `index` (Chat Completions) or by
    /// `item_id` (Responses).
    private(set) var entriesByKey: [String: Entry] = [:]
    private(set) var orderedKeys: [String] = []

    /// Returns `true` if a new entry was created (caller should emit
    /// `.toolCallStart` if a name is now known and this is the first sighting).
    @discardableResult
    func upsert(key: String, id: String?, name: String?, argumentsDelta: String?) -> Bool {
        if var existing = entriesByKey[key] {
            // Sticky id: first non-empty id wins.
            if existing.id.isEmpty, let id, !id.isEmpty {
                existing.id = id
            }
            if existing.name.isEmpty, let name, !name.isEmpty {
                existing.name = name
            }
            if let argumentsDelta {
                existing.arguments.append(argumentsDelta)
            }
            entriesByKey[key] = existing
            return false
        } else {
            let entry = Entry(
                id: id ?? "",
                name: name ?? "",
                arguments: argumentsDelta ?? "",
                started: false
            )
            entriesByKey[key] = entry
            orderedKeys.append(key)
            return true
        }
    }

    /// Marks the entry's `.toolCallStart` as emitted.
    func markStarted(key: String) {
        guard var entry = entriesByKey[key] else { return }
        entry.started = true
        entriesByKey[key] = entry
    }

    /// Returns the resolved call id for this key, synthesising a deterministic
    /// fallback when the wire never delivered one (rare, but observed on some
    /// compat servers).
    func resolvedId(forKey key: String) -> String {
        guard let entry = entriesByKey[key] else { return key }
        if !entry.id.isEmpty { return entry.id }
        // Fallback: stable per-stream id derived from the key. Ids are only
        // used for call/result pairing inside one turn so a deterministic
        // synthetic value is sufficient.
        return "openai-call-\(key)"
    }

    /// Returns all completed entries in insertion order. `entry.arguments`
    /// is normalised to `"{}"` when empty so downstream JSON consumers can
    /// always parse the value.
    func finalizedEntries() -> [(callId: String, name: String, arguments: String)] {
        orderedKeys.compactMap { key in
            guard let entry = entriesByKey[key] else { return nil }
            let id = !entry.id.isEmpty ? entry.id : "openai-call-\(key)"
            let name = entry.name
            // Drop entries with no name — the model never finished declaring
            // them, so we can't dispatch them anyway.
            guard !name.isEmpty else { return nil }
            let args = entry.arguments.isEmpty ? "{}" : entry.arguments
            return (callId: id, name: name, arguments: args)
        }
    }
}
#endif

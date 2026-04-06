import Foundation

/// Maximum number of tool call rounds per generation to prevent runaway loops.
///
/// Each round may contain one or more tool calls. After this limit, the backend
/// should stop calling tools and return whatever text the model has generated.
public let maximumToolCallRounds = 10

/// Opt-in protocol for backends that support tool/function calling.
///
/// Backends that adopt this protocol can accept tool definitions and execute
/// tool calls during generation. The tool-calling loop runs inside the backend:
/// `generate()` still returns `AsyncThrowingStream<String, Error>` so consumers
/// see only text tokens, while tool calls happen transparently.
///
/// For backends that want to surface tool call activity to the UI, the
/// `toolCallObserver` property allows an observer to receive notifications.
public protocol ToolCallingBackend: InferenceBackend {
    /// Sets the tools available for the next generation call.
    ///
    /// Pass an empty array to disable tool calling for the next request.
    /// Called by `InferenceService` before `generate()` when a `ToolProvider`
    /// is configured.
    func setTools(_ tools: [ToolDefinition])

    /// Sets the tool provider for executing tool calls during generation.
    ///
    /// The backend calls `execute(_:)` on this provider when the model
    /// requests a tool call, feeding the result back to the model.
    func setToolProvider(_ provider: (any ToolProvider)?)

    /// Optional observer for tool call activity.
    var toolCallObserver: (any ToolCallObserver)? { get set }
}

/// Opt-in protocol for backends that support structured/constrained output.
///
/// Backends adopt this to support JSON schema output or grammar-constrained
/// generation. The mechanism varies by backend:
/// - OpenAI: `response_format: { type: "json_schema", json_schema: ... }`
/// - LlamaBackend: GBNF grammar constraints via `llama_sampler_init_grammar`
public protocol StructuredGenerationBackend: InferenceBackend {
    /// Generates a structured response matching the given grammar constraint.
    ///
    /// The output is decoded into `T` before returning. Throws if the model
    /// output does not match the expected schema.
    func generateStructured<T: Decodable>(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        constraint: GrammarConstraint,
        type: T.Type
    ) async throws -> T
}

/// Describes a constraint on model output format.
public enum GrammarConstraint: Sendable, Equatable {
    /// A GBNF grammar string for llama.cpp-style backends.
    case gbnf(String)
    /// A JSON schema (serialized as Data) that the output must conform to.
    case jsonSchema(Data)

    /// Creates a JSON schema constraint from a dictionary.
    public static func jsonSchema(from dictionary: [String: Any]) throws -> GrammarConstraint {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: .sortedKeys)
        return .jsonSchema(data)
    }

    /// Returns the JSON schema as a dictionary, or nil if not a jsonSchema constraint.
    public func schemaAsDictionary() -> [String: Any]? {
        guard case .jsonSchema(let data) = self else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Converts a JSON schema constraint to a basic GBNF grammar string.
    ///
    /// Handles flat object schemas with string, number, integer, and boolean
    /// properties. Nested schemas require hand-written GBNF.
    public func toGBNF() -> String? {
        switch self {
        case .gbnf(let grammar):
            return grammar
        case .jsonSchema(let data):
            guard let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return Self.schemaToGBNF(schema)
        }
    }

    private static func schemaToGBNF(_ schema: [String: Any]) -> String? {
        guard let type = schema["type"] as? String else { return nil }

        switch type {
        case "object":
            guard let properties = schema["properties"] as? [String: [String: Any]] else {
                return #"root ::= "{" ws "}" ws"#
            }
            let sortedKeys = properties.keys.sorted()
            var rules = [String]()
            var propertyRules = [String]()

            for (index, key) in sortedKeys.enumerated() {
                let propSchema = properties[key] ?? [:]
                let propType = propSchema["type"] as? String ?? "string"
                let propRule = "\(key)-value"
                let separator = index < sortedKeys.count - 1 ? #" "," ws "#  : ""

                propertyRules.append(#""\#(key)" ws ":" ws \#(propRule)\#(separator)"#)

                switch propType {
                case "string":
                    rules.append(#"\#(propRule) ::= "\"" [^"]* "\""  "#)
                case "number":
                    rules.append("\(propRule) ::= [\"-\"]? [0-9]+ (\".\" [0-9]+)?")
                case "integer":
                    rules.append("\(propRule) ::= [\"-\"]? [0-9]+")
                case "boolean":
                    rules.append(#"\#(propRule) ::= ("true" | "false")"#)
                default:
                    rules.append(#"\(propRule) ::= "\"" [^"]* "\""  "#)
                }
            }

            let rootRule = #"root ::= "{" ws \#(propertyRules.joined(separator: " ")) ws "}" ws"#
            let wsRule = #"ws ::= [ \t\n]*"#
            return ([rootRule] + rules + [wsRule]).joined(separator: "\n")

        case "string":
            return #"root ::= "\"" [^"]* "\""  "#
        case "number":
            return "root ::= [\"-\"]? [0-9]+ (\".\" [0-9]+)?"
        case "integer":
            return "root ::= [\"-\"]? [0-9]+"
        case "boolean":
            return #"root ::= ("true" | "false")"#
        default:
            return nil
        }
    }
}

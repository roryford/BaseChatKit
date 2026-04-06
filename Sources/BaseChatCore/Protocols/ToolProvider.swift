import Foundation

// MARK: - Tool Definition Types

/// Describes a single parameter in a tool's input schema.
public struct ToolParameterProperty: Sendable, Equatable, Codable {
    public let type: String
    public let description: String
    public let enumValues: [String]?

    public init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
    }
}

/// JSON Schema-style input schema for a tool definition.
public struct ToolInputSchema: Sendable, Equatable, Codable {
    public let type: String
    public let properties: [String: ToolParameterProperty]
    public let required: [String]

    public init(
        properties: [String: ToolParameterProperty],
        required: [String] = []
    ) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

/// Describes a tool that an LLM can invoke during generation.
public struct ToolDefinition: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let inputSchema: ToolInputSchema

    public init(name: String, description: String, inputSchema: ToolInputSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Serializes this definition to a JSON-compatible dictionary for API payloads.
    public func toJSON() -> [String: Any] {
        var schema: [String: Any] = ["type": inputSchema.type]
        var props: [String: Any] = [:]
        for (key, prop) in inputSchema.properties {
            var propDict: [String: Any] = [
                "type": prop.type,
                "description": prop.description
            ]
            if let enumValues = prop.enumValues {
                propDict["enum"] = enumValues
            }
            props[key] = propDict
        }
        schema["properties"] = props
        if !inputSchema.required.isEmpty {
            schema["required"] = inputSchema.required
        }
        return [
            "name": name,
            "description": description,
            "input_schema": schema
        ]
    }
}

/// A tool invocation requested by the model.
public struct ToolCall: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Parses the arguments JSON string into a dictionary.
    public func parsedArguments() throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolCallingError.invalidArguments(toolName: name, raw: arguments)
        }
        return dict
    }
}

/// The result of executing a tool.
public struct ToolResult: Sendable, Equatable, Codable {
    public let toolCallID: String
    public let content: String
    public let isError: Bool

    public init(toolCallID: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

// MARK: - Tool Provider Protocol

/// Vends tool definitions and executes tool calls.
///
/// Conformers declare which tools are available and handle execution when
/// the model requests a tool call. The framework handles the plumbing
/// between model output and tool execution.
public protocol ToolProvider: Sendable {
    /// The tools available for the model to call.
    var tools: [ToolDefinition] { get }

    /// Executes a tool call and returns the result.
    ///
    /// Implementations should return a `ToolResult` with `isError: true` for
    /// recoverable failures rather than throwing, so the model can see the error
    /// and try a different approach.
    func execute(_ toolCall: ToolCall) async throws -> ToolResult
}

// MARK: - Tool Calling Errors

/// Errors specific to tool calling infrastructure.
public enum ToolCallingError: Error, Equatable, Sendable {
    case invalidArguments(toolName: String, raw: String)
    case unknownTool(name: String)
    case toolCallLimitExceeded(limit: Int)
}

// MARK: - Tool Call Observer

/// Observes tool call activity during generation.
///
/// Adopt this protocol to display tool calls and results in the UI
/// as they happen during a generation cycle.
public protocol ToolCallObserver: AnyObject, Sendable {
    /// Called when the model requests a tool call.
    func didRequestToolCall(_ toolCall: ToolCall) async

    /// Called when a tool call completes with a result.
    func didReceiveToolResult(_ result: ToolResult, for toolCall: ToolCall) async
}

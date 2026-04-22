import Foundation

// MARK: - ToolExecutor

/// A runtime-executable tool definition.
///
/// Conformers pair a ``ToolDefinition`` (the JSON-Schema contract the model
/// sees) with an `execute(arguments:)` hook that runs the tool and returns a
/// ``ToolResult``. Executors are stored in a ``ToolRegistry`` and dispatched
/// by the orchestration loop when the model emits a ``ToolCall``.
///
/// ## Arguments type
///
/// The protocol intentionally takes ``JSONSchemaValue`` — not a raw `String`
/// — so adapter layers (MCP bridges, AppIntents, macro-generated tools) can
/// hand a structured, already-parsed argument tree to the executor without
/// re-serialising through a string. ``ToolRegistry/dispatch(_:)`` handles the
/// `String`→`JSONSchemaValue` parse at the registry boundary.
///
/// ## Typed adapter
///
/// Most callers do not implement this protocol directly. Use
/// ``TypedToolExecutor`` to wrap a strongly-typed Swift handler — the adapter
/// handles JSON encode/decode on both sides so the handler signature stays
/// free of `JSONSchemaValue`.
public protocol ToolExecutor: Sendable {

    /// The JSON-Schema contract exposed to the model and the ``ToolRegistry``
    /// lookup key. ``ToolDefinition/name`` must be unique within a registry
    /// (case-insensitive).
    var definition: ToolDefinition { get }

    /// Executes the tool with already-parsed JSON arguments.
    ///
    /// The returned ``ToolResult/callId`` may be empty — ``ToolRegistry``
    /// stamps the correct id from the incoming ``ToolCall`` before returning
    /// the result to the caller. Thrown errors are caught by the registry and
    /// turned into ``ToolResult/ErrorKind/permanent`` results.
    func execute(arguments: JSONSchemaValue) async throws -> ToolResult
}

// MARK: - TypedToolExecutor

/// Generic adapter that exposes a strongly-typed Swift handler as a
/// ``ToolExecutor``.
///
/// The adapter owns three responsibilities:
/// 1. Decode the incoming ``JSONSchemaValue`` into `Arguments` via `JSONDecoder`.
/// 2. Call the handler.
/// 3. Encode the handler's `Result` as a JSON string and wrap it in a ``ToolResult``.
///
/// ```swift
/// struct WeatherArgs: Decodable, Sendable { let city: String }
/// struct WeatherResult: Encodable, Sendable { let summary: String; let celsius: Double }
///
/// let weather = TypedToolExecutor<WeatherArgs, WeatherResult>(
///     definition: ToolDefinition(name: "get_weather", description: "Returns weather.", parameters: schema)
/// ) { args in
///     WeatherResult(summary: "Sunny", celsius: 22.0)
/// }
/// registry.register(weather)
/// ```
///
/// Decode or encode failures throw — ``ToolRegistry/dispatch(_:)`` catches them
/// and returns a ``ToolResult/ErrorKind/permanent`` result. Malformed JSON in
/// the raw ``ToolCall/arguments`` string is classified as
/// ``ToolResult/ErrorKind/invalidArguments`` at the registry boundary before
/// this adapter sees it.
public struct TypedToolExecutor<Arguments: Decodable & Sendable, Result: Encodable & Sendable>: ToolExecutor {

    public let definition: ToolDefinition

    private let handler: @Sendable (Arguments) async throws -> Result

    /// Creates a typed executor.
    ///
    /// - Parameters:
    ///   - definition: The tool contract exposed to the model. ``ToolDefinition/parameters``
    ///     should describe the JSON shape of `Arguments`.
    ///   - handler: Runs the tool. Thrown errors become ``ToolResult/ErrorKind/permanent``
    ///     results at the registry layer.
    public init(
        definition: ToolDefinition,
        handler: @Sendable @escaping (Arguments) async throws -> Result
    ) {
        self.definition = definition
        self.handler = handler
    }

    public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        // Route through Data so we don't need a bespoke bridge between
        // JSONSchemaValue and arbitrary Decodable types — Foundation already
        // handles the decode perfectly via the standard JSON path.
        let argsData = try JSONEncoder().encode(arguments)
        let decoded = try JSONDecoder().decode(Arguments.self, from: argsData)
        let result = try await handler(decoded)

        let resultData = try JSONEncoder().encode(result)
        // Prefer a UTF-8 string so the model receives readable JSON rather than
        // base64. JSON encoders always emit valid UTF-8, so the force is safe.
        let content = String(data: resultData, encoding: .utf8) ?? ""

        // callId is intentionally empty here — ToolRegistry.dispatch stamps the
        // correct id from the incoming ToolCall before returning to the caller.
        return ToolResult(callId: "", content: content, errorKind: nil)
    }
}

import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

/// Tests for tool calling core types: ToolDefinition, ToolCall, ToolResult, and ToolProvider.
final class ToolProviderTests: XCTestCase {

    // MARK: - ToolDefinition JSON Serialization

    func test_toolDefinition_toJSON_includesAllFields() {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get the current weather",
            inputSchema: ToolInputSchema(
                properties: [
                    "location": ToolParameterProperty(type: "string", description: "City name"),
                    "units": ToolParameterProperty(type: "string", description: "Temperature units", enumValues: ["celsius", "fahrenheit"])
                ],
                required: ["location"]
            )
        )

        let json = tool.toJSON()

        XCTAssertEqual(json["name"] as? String, "get_weather")
        XCTAssertEqual(json["description"] as? String, "Get the current weather")

        let schema = json["input_schema"] as? [String: Any]
        XCTAssertNotNil(schema)
        XCTAssertEqual(schema?["type"] as? String, "object")

        let properties = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(properties)

        let location = properties?["location"] as? [String: Any]
        XCTAssertEqual(location?["type"] as? String, "string")
        XCTAssertEqual(location?["description"] as? String, "City name")

        let units = properties?["units"] as? [String: Any]
        XCTAssertEqual(units?["enum"] as? [String], ["celsius", "fahrenheit"])

        XCTAssertEqual(schema?["required"] as? [String], ["location"])
    }

    func test_toolDefinition_toJSON_omitsRequiredWhenEmpty() {
        let tool = ToolDefinition(
            name: "simple",
            description: "A simple tool",
            inputSchema: ToolInputSchema(properties: [:])
        )

        let json = tool.toJSON()
        let schema = json["input_schema"] as? [String: Any]

        // required key should still be present but as empty array
        // (API providers expect the key to exist)
        let required = schema?["required"] as? [String]
        XCTAssertTrue(required?.isEmpty ?? true)
    }

    // MARK: - ToolDefinition Codable

    func test_toolDefinition_codableRoundTrip() throws {
        let tool = ToolDefinition(
            name: "search",
            description: "Search the web",
            inputSchema: ToolInputSchema(
                properties: [
                    "query": ToolParameterProperty(type: "string", description: "Search query")
                ],
                required: ["query"]
            )
        )

        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(ToolDefinition.self, from: data)

        XCTAssertEqual(decoded, tool)
    }

    // MARK: - ToolParameterProperty Enum Values

    func test_parameterProperty_withEnumValues() throws {
        let prop = ToolParameterProperty(
            type: "string",
            description: "Color choice",
            enumValues: ["red", "blue", "green"]
        )

        let data = try JSONEncoder().encode(prop)
        let decoded = try JSONDecoder().decode(ToolParameterProperty.self, from: data)

        XCTAssertEqual(decoded.enumValues, ["red", "blue", "green"])
    }

    func test_parameterProperty_withoutEnumValues() throws {
        let prop = ToolParameterProperty(type: "number", description: "A number")

        let data = try JSONEncoder().encode(prop)
        let decoded = try JSONDecoder().decode(ToolParameterProperty.self, from: data)

        XCTAssertNil(decoded.enumValues)
    }

    // MARK: - ToolCall

    func test_toolCall_parsedArguments_validJSON() throws {
        let call = ToolCall(
            id: "call_1",
            name: "get_weather",
            arguments: #"{"location": "London", "units": "celsius"}"#
        )

        let args = try call.parsedArguments()
        XCTAssertEqual(args["location"] as? String, "London")
        XCTAssertEqual(args["units"] as? String, "celsius")
    }

    func test_toolCall_parsedArguments_invalidJSON_throws() {
        let call = ToolCall(
            id: "call_2",
            name: "bad_tool",
            arguments: "not json"
        )

        XCTAssertThrowsError(try call.parsedArguments()) { error in
            guard case ToolCallingError.invalidArguments(let name, _) = error else {
                XCTFail("Expected invalidArguments, got \(error)")
                return
            }
            XCTAssertEqual(name, "bad_tool")
        }
    }

    func test_toolCall_codableRoundTrip() throws {
        let call = ToolCall(id: "tc_1", name: "search", arguments: #"{"q":"test"}"#)
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
        XCTAssertEqual(decoded, call)
    }

    // MARK: - ToolResult

    func test_toolResult_codableRoundTrip() throws {
        let result = ToolResult(toolCallID: "tc_1", content: "72°F", isError: false)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func test_toolResult_errorResult() {
        let result = ToolResult(toolCallID: "tc_2", content: "Tool not found", isError: true)
        XCTAssertTrue(result.isError)
    }

    // MARK: - MockToolProvider

    func test_mockToolProvider_executesAndTracksCalls() async throws {
        let tool = ToolDefinition(
            name: "greet",
            description: "Greet someone",
            inputSchema: ToolInputSchema(
                properties: ["name": ToolParameterProperty(type: "string", description: "Name")],
                required: ["name"]
            )
        )
        let provider = MockToolProvider(
            tools: [tool],
            results: ["greet": ToolResult(toolCallID: "", content: "Hello, World!")]
        )

        let call = ToolCall(id: "call_1", name: "greet", arguments: #"{"name":"World"}"#)
        let result = try await provider.execute(call)

        XCTAssertEqual(result.content, "Hello, World!")
        XCTAssertEqual(result.toolCallID, "call_1")
        XCTAssertEqual(provider.receivedCalls.count, 1)
        XCTAssertEqual(provider.receivedCalls.first?.name, "greet")
    }

    func test_mockToolProvider_unknownTool_returnsDefault() async throws {
        let provider = MockToolProvider()
        let call = ToolCall(id: "call_1", name: "unknown", arguments: "{}")
        let result = try await provider.execute(call)

        XCTAssertEqual(result.content, "Mock result for unknown")
        XCTAssertFalse(result.isError)
    }

    func test_mockToolProvider_throwsWhenConfigured() async {
        let provider = MockToolProvider()
        provider.shouldThrow = ToolCallingError.unknownTool(name: "bad")

        let call = ToolCall(id: "call_1", name: "bad", arguments: "{}")
        do {
            _ = try await provider.execute(call)
            XCTFail("Should throw")
        } catch {
            guard case ToolCallingError.unknownTool = error else {
                XCTFail("Expected unknownTool, got \(error)")
                return
            }
        }
    }

    // MARK: - ToolCallingError

    func test_toolCallingError_equatable() {
        XCTAssertEqual(
            ToolCallingError.unknownTool(name: "foo"),
            ToolCallingError.unknownTool(name: "foo")
        )
        XCTAssertNotEqual(
            ToolCallingError.unknownTool(name: "foo"),
            ToolCallingError.unknownTool(name: "bar")
        )
        XCTAssertEqual(
            ToolCallingError.toolCallLimitExceeded(limit: 10),
            ToolCallingError.toolCallLimitExceeded(limit: 10)
        )
    }
}

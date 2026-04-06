import XCTest
import BaseChatCore
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for OpenAIBackend tool calling: tool_calls delta parsing,
/// tool definition serialization in requests, and capabilities.
final class OpenAIToolCallingTests: XCTestCase {

    // MARK: - Capabilities

    func test_capabilities_supportsToolCalling() {
        let backend = OpenAIBackend()
        XCTAssertTrue(backend.capabilities.supportsToolCalling)
    }

    func test_capabilities_supportsStructuredOutput() {
        let backend = OpenAIBackend()
        XCTAssertTrue(backend.capabilities.supportsStructuredOutput)
    }

    // MARK: - Tool Call Parsing

    func test_parseToolCalls_validDelta() {
        let json = """
        {
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "id": "call_abc123",
                        "type": "function",
                        "function": {
                            "name": "get_weather",
                            "arguments": "{\\"location\\": \\"London\\"}"
                        }
                    }]
                }
            }]
        }
        """

        let toolCalls = OpenAIBackend.parseToolCalls(from: json)
        XCTAssertNotNil(toolCalls)
        XCTAssertEqual(toolCalls?.count, 1)
        XCTAssertEqual(toolCalls?.first?.id, "call_abc123")
        XCTAssertEqual(toolCalls?.first?.name, "get_weather")

        if let call = toolCalls?.first {
            let args = try? call.parsedArguments()
            XCTAssertEqual(args?["location"] as? String, "London")
        }
    }

    func test_parseToolCalls_multipleToolCalls() {
        let json = """
        {
            "choices": [{
                "delta": {
                    "tool_calls": [
                        {
                            "id": "call_1",
                            "function": {"name": "get_weather", "arguments": "{}"}
                        },
                        {
                            "id": "call_2",
                            "function": {"name": "get_time", "arguments": "{}"}
                        }
                    ]
                }
            }]
        }
        """

        let toolCalls = OpenAIBackend.parseToolCalls(from: json)
        XCTAssertEqual(toolCalls?.count, 2)
        XCTAssertEqual(toolCalls?[0].name, "get_weather")
        XCTAssertEqual(toolCalls?[1].name, "get_time")
    }

    func test_parseToolCalls_noToolCalls_returnsNil() {
        let json = """
        {
            "choices": [{
                "delta": {
                    "content": "Hello world"
                }
            }]
        }
        """

        XCTAssertNil(OpenAIBackend.parseToolCalls(from: json))
    }

    func test_parseToolCalls_emptyArguments() {
        let json = """
        {
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "id": "call_1",
                        "function": {"name": "no_args"}
                    }]
                }
            }]
        }
        """

        let toolCalls = OpenAIBackend.parseToolCalls(from: json)
        XCTAssertEqual(toolCalls?.first?.arguments, "{}")
    }

    // MARK: - Tool Definitions in Request

    func test_buildRequest_includesToolDefinitions() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

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
        backend.setTools([tool])

        let request = try backend.buildRequest(
            prompt: "Search for cats",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let tools = body["tools"] as? [[String: Any]]

        XCTAssertNotNil(tools)
        XCTAssertEqual(tools?.count, 1)

        let firstTool = tools?.first
        XCTAssertEqual(firstTool?["type"] as? String, "function")

        let function = firstTool?["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "search")
        XCTAssertEqual(function?["description"] as? String, "Search the web")

        let params = function?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
        XCTAssertEqual(params?["required"] as? [String], ["query"])
    }

    func test_buildRequest_excludesToolsWhenEmpty() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        backend.setTools([])

        let request = try backend.buildRequest(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertNil(body["tools"])
    }

    // MARK: - ToolCallingBackend Conformance

    func test_setTools_storesDefinitions() {
        let backend = OpenAIBackend()
        let tool = ToolDefinition(
            name: "test",
            description: "Test",
            inputSchema: ToolInputSchema(properties: [:])
        )
        backend.setTools([tool])
        backend.setTools([])
    }

    func test_setToolProvider_storesAndClearsProvider() {
        let backend = OpenAIBackend()
        let provider = MockToolProvider()

        backend.setToolProvider(provider)
        backend.setToolProvider(nil)
    }
}

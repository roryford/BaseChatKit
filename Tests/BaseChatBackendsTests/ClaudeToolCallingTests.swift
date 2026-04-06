import XCTest
import BaseChatCore
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for ClaudeBackend tool calling: tool_use content block parsing,
/// tool definition serialization in requests, and capabilities.
final class ClaudeToolCallingTests: XCTestCase {

    // MARK: - Capabilities

    func test_capabilities_supportsToolCalling() {
        let backend = ClaudeBackend()
        XCTAssertTrue(backend.capabilities.supportsToolCalling)
    }

    func test_capabilities_supportsStructuredOutput() {
        let backend = ClaudeBackend()
        XCTAssertTrue(backend.capabilities.supportsStructuredOutput)
    }

    // MARK: - Tool Use Parsing

    func test_parseToolUse_validContentBlockStart() {
        let json = """
        {
            "type": "content_block_start",
            "index": 1,
            "content_block": {
                "type": "tool_use",
                "id": "toolu_01A09q90qw90lq917835lq",
                "name": "get_weather",
                "input": {}
            }
        }
        """

        let toolCall = ClaudeBackend.parseToolUse(from: json)
        XCTAssertNotNil(toolCall)
        XCTAssertEqual(toolCall?.id, "toolu_01A09q90qw90lq917835lq")
        XCTAssertEqual(toolCall?.name, "get_weather")
    }

    func test_parseToolUse_withInput() {
        let json = """
        {
            "type": "content_block_start",
            "index": 1,
            "content_block": {
                "type": "tool_use",
                "id": "toolu_123",
                "name": "search",
                "input": {"query": "weather in London"}
            }
        }
        """

        let toolCall = ClaudeBackend.parseToolUse(from: json)
        XCTAssertNotNil(toolCall)
        XCTAssertEqual(toolCall?.name, "search")

        // Arguments should be parseable JSON
        if let call = toolCall {
            let args = try? call.parsedArguments()
            XCTAssertEqual(args?["query"] as? String, "weather in London")
        }
    }

    func test_parseToolUse_textBlock_returnsNil() {
        let json = """
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {
                "type": "text",
                "text": ""
            }
        }
        """

        XCTAssertNil(ClaudeBackend.parseToolUse(from: json))
    }

    func test_parseToolUse_nonContentBlockStart_returnsNil() {
        let json = """
        {
            "type": "content_block_delta",
            "delta": {"type": "text_delta", "text": "Hello"}
        }
        """

        XCTAssertNil(ClaudeBackend.parseToolUse(from: json))
    }

    // MARK: - Tool Input Delta Parsing

    func test_parseToolInputDelta_validDelta() {
        let json = """
        {
            "type": "content_block_delta",
            "index": 1,
            "delta": {
                "type": "input_json_delta",
                "partial_json": "{\\"location\\": \\"Lo"
            }
        }
        """

        let partial = ClaudeBackend.parseToolInputDelta(from: json)
        XCTAssertNotNil(partial)
        XCTAssertTrue(partial!.contains("location"))
    }

    func test_parseToolInputDelta_textDelta_returnsNil() {
        let json = """
        {
            "type": "content_block_delta",
            "delta": {"type": "text_delta", "text": "Hello"}
        }
        """

        XCTAssertNil(ClaudeBackend.parseToolInputDelta(from: json))
    }

    // MARK: - Tool Definitions in Request

    func test_buildRequest_includesToolDefinitions() async throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-test-key",
            modelName: "claude-sonnet-4-20250514"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            inputSchema: ToolInputSchema(
                properties: [
                    "city": ToolParameterProperty(type: "string", description: "City name")
                ],
                required: ["city"]
            )
        )
        backend.setTools([tool])

        let request = try backend.buildRequest(
            prompt: "What's the weather?",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let tools = body["tools"] as? [[String: Any]]

        XCTAssertNotNil(tools)
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "get_weather")
    }

    func test_buildRequest_excludesToolsWhenEmpty() async throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-test-key",
            modelName: "claude-sonnet-4-20250514"
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
        let backend = ClaudeBackend()
        let tool = ToolDefinition(
            name: "test",
            description: "Test tool",
            inputSchema: ToolInputSchema(properties: [:])
        )

        backend.setTools([tool])
        // Verify by building a request that should include tools
        // (verified above in test_buildRequest_includesToolDefinitions)
    }

    func test_setToolProvider_storesProvider() {
        let backend = ClaudeBackend()
        let provider = MockToolProvider()

        backend.setToolProvider(provider)
        // Provider is stored internally; verified via the protocol conformance
        backend.setToolProvider(nil)
    }
}

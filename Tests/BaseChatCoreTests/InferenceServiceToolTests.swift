import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

/// Tests that InferenceService propagates tool provider and definitions
/// to backends that adopt ToolCallingBackend.
@MainActor
final class InferenceServiceToolTests: XCTestCase {

    // MARK: - Tool Propagation

    func test_generate_propagatesToolsToConformingBackend() async throws {
        let backend = MockToolCallingBackend()
        let service = InferenceService(backend: backend, name: "ToolMock")

        let tool = ToolDefinition(
            name: "test_tool",
            description: "A test tool",
            inputSchema: ToolInputSchema(properties: [:])
        )
        let provider = MockToolProvider(tools: [tool])
        service.toolProvider = provider

        _ = try service.generate(
            messages: [("user", "hello")],
            systemPrompt: nil
        )

        XCTAssertEqual(backend.lastToolDefinitions?.count, 1)
        XCTAssertEqual(backend.lastToolDefinitions?.first?.name, "test_tool")
        XCTAssertNotNil(backend.lastToolProvider)
    }

    func test_generate_clearsToolsWhenNoProvider() async throws {
        let backend = MockToolCallingBackend()
        let service = InferenceService(backend: backend, name: "ToolMock")

        // First generate with tools
        let tool = ToolDefinition(
            name: "temp_tool",
            description: "Temporary",
            inputSchema: ToolInputSchema(properties: [:])
        )
        service.toolProvider = MockToolProvider(tools: [tool])
        _ = try service.generate(messages: [("user", "hi")], systemPrompt: nil)
        XCTAssertEqual(backend.lastToolDefinitions?.count, 1)

        // Then generate without tools
        service.toolProvider = nil
        _ = try service.generate(messages: [("user", "hi again")], systemPrompt: nil)
        XCTAssertTrue(backend.lastToolDefinitions?.isEmpty ?? true)
    }

    func test_generate_doesNotCrashWithNonToolBackend() throws {
        // Regular MockInferenceBackend does not adopt ToolCallingBackend
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "Regular")

        let tool = ToolDefinition(
            name: "test",
            description: "Test",
            inputSchema: ToolInputSchema(properties: [:])
        )
        service.toolProvider = MockToolProvider(tools: [tool])

        // Should not crash — tools are silently ignored for non-conforming backends
        _ = try service.generate(messages: [("user", "hello")])
    }

    func test_toolCallObserver_propagatesToBackend() {
        let backend = MockToolCallingBackend()
        let service = InferenceService(backend: backend, name: "ToolMock")

        let observer = MockToolCallObserver()
        service.toolCallObserver = observer

        XCTAssertNotNil(backend.toolCallObserver)
    }

    // MARK: - Capabilities

    func test_toolCallingBackend_reportsSupportInCapabilities() {
        let backend = MockToolCallingBackend()
        XCTAssertTrue(backend.capabilities.supportsToolCalling)
    }
}

// MARK: - Mock Tool Calling Backend

/// A mock backend that conforms to ToolCallingBackend for testing propagation.
private final class MockToolCallingBackend: InferenceBackend, ToolCallingBackend, ConversationHistoryReceiver, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false

    var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )
    }

    var lastToolDefinitions: [ToolDefinition]?
    var lastToolProvider: (any ToolProvider)?
    var toolCallObserver: (any ToolCallObserver)?

    func setTools(_ tools: [ToolDefinition]) {
        lastToolDefinitions = tools
    }

    func setToolProvider(_ provider: (any ToolProvider)?) {
        lastToolProvider = provider
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.token("response"))
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() {}

    func setConversationHistory(_ messages: [(role: String, content: String)]) {}
}

// MARK: - Mock Tool Call Observer

@MainActor
private final class MockToolCallObserver: ToolCallObserver {
    var receivedToolCalls: [ToolCall] = []
    var receivedResults: [(result: ToolResult, call: ToolCall)] = []

    func didRequestToolCall(_ toolCall: ToolCall) async {
        receivedToolCalls.append(toolCall)
    }

    func didReceiveToolResult(_ result: ToolResult, for toolCall: ToolCall) async {
        receivedResults.append((result, toolCall))
    }
}

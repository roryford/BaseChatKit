import Foundation
import BaseChatCore

/// Configurable mock tool provider for testing tool-calling infrastructure.
///
/// Returns canned results for tool calls. Tracks all calls received for assertions.
public final class MockToolProvider: ToolProvider, @unchecked Sendable {

    public var tools: [ToolDefinition]
    public var results: [String: ToolResult]
    public private(set) var receivedCalls: [ToolCall] = []

    /// If set, `execute` throws this error instead of returning a result.
    public var shouldThrow: Error?

    /// Creates a mock tool provider.
    ///
    /// - Parameters:
    ///   - tools: Tool definitions to advertise.
    ///   - results: Mapping from tool name to canned result.
    public init(
        tools: [ToolDefinition] = [],
        results: [String: ToolResult] = [:]
    ) {
        self.tools = tools
        self.results = results
    }

    public func execute(_ toolCall: ToolCall) async throws -> ToolResult {
        receivedCalls.append(toolCall)

        if let error = shouldThrow {
            throw error
        }

        if let result = results[toolCall.name] {
            return ToolResult(
                toolCallID: toolCall.id,
                content: result.content,
                isError: result.isError
            )
        }

        return ToolResult(
            toolCallID: toolCall.id,
            content: "Mock result for \(toolCall.name)",
            isError: false
        )
    }
}

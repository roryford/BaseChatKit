import Foundation
import BaseChatCore

/// Configurable mock tool provider for testing tool-calling infrastructure.
///
/// Returns canned results for tool calls. Tracks all calls received for assertions.
/// Uses a lock to protect mutable state since `execute` is async and may be
/// called from multiple tasks concurrently.
public final class MockToolProvider: ToolProvider, @unchecked Sendable {

    private let lock = NSLock()

    private var _tools: [ToolDefinition]
    private var _results: [String: ToolResult]
    private var _receivedCalls: [ToolCall] = []
    private var _shouldThrow: Error?

    public var tools: [ToolDefinition] {
        get { lock.withLock { _tools } }
        set { lock.withLock { _tools = newValue } }
    }

    public var results: [String: ToolResult] {
        get { lock.withLock { _results } }
        set { lock.withLock { _results = newValue } }
    }

    public var receivedCalls: [ToolCall] {
        lock.withLock { _receivedCalls }
    }

    /// If set, `execute` throws this error instead of returning a result.
    public var shouldThrow: Error? {
        get { lock.withLock { _shouldThrow } }
        set { lock.withLock { _shouldThrow = newValue } }
    }

    /// Creates a mock tool provider.
    ///
    /// - Parameters:
    ///   - tools: Tool definitions to advertise.
    ///   - results: Mapping from tool name to canned result.
    public init(
        tools: [ToolDefinition] = [],
        results: [String: ToolResult] = [:]
    ) {
        self._tools = tools
        self._results = results
    }

    public func execute(_ toolCall: ToolCall) async throws -> ToolResult {
        let (error, cannedResult) = lock.withLock {
            _receivedCalls.append(toolCall)
            return (_shouldThrow, _results[toolCall.name])
        }

        if let error {
            throw error
        }

        if let cannedResult {
            return ToolResult(
                toolCallID: toolCall.id,
                content: cannedResult.content,
                isError: cannedResult.isError
            )
        }

        return ToolResult(
            toolCallID: toolCall.id,
            content: "Mock result for \(toolCall.name)",
            isError: false
        )
    }
}

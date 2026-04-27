#if Llama
import XCTest
@testable import BaseChatInference
@testable import BaseChatBackends

/// Unit tests for ``LlamaToolCallParser``.
///
/// These tests exercise the parser logic only — no GGUF model is loaded and
/// no hardware-specific symbols are invoked. They run under
/// `swift test --filter BaseChatBackendsTests --disable-default-traits`.
final class LlamaToolCallParserTests: XCTestCase {

    // MARK: - Gemma 4 native format

    func test_gemma4NativeCall_singleCall_emitsToolCallEvent() {
        var parser = LlamaToolCallParser()
        let input = "<|tool_call>\ncall:get_weather{city:<|\"|>London<|\"|>,units:<|\"|>celsius<|\"|>}\n<|end_of_turn>"
        let events = parser.process(input)

        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        let tc = try XCTUnwrap(toolCalls.first)
        XCTAssertEqual(tc.toolName, "get_weather")

        let args = try XCTUnwrap(tc.arguments.data(using: .utf8))
        let decoded = try XCTUnwrap(try? JSONSerialization.jsonObject(with: args) as? [String: Any])
        XCTAssertEqual(decoded["city"] as? String, "London")
        XCTAssertEqual(decoded["units"] as? String, "celsius")
    }

    func test_gemma4NativeCall_noArgs_emitsToolCallWithEmptyArgs() {
        var parser = LlamaToolCallParser()
        let input = "<|tool_call>\ncall:list_files{}\n<|end_of_turn>"
        let events = parser.process(input)

        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "list_files")
    }

    func test_gemma4NativeCall_prefixText_emitsTokenBeforeToolCall() {
        var parser = LlamaToolCallParser()
        let input = "Sure, let me check that.<|tool_call>\ncall:get_time{}\n<|end_of_turn>"
        let events = parser.process(input)

        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t }
            return nil
        }
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertFalse(tokens.isEmpty, "Expected token events before tool call")
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "get_time")
    }

    // MARK: - JSON fallback format

    func test_jsonFallback_singleCall_emitsToolCallEvent() {
        var parser = LlamaToolCallParser()
        let input = """
        <tool_call>
        {"name":"search","arguments":{"query":"swift concurrency"}}
        </tool_call>
        """
        let events = parser.process(input)
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "search")
    }

    func test_jsonFallback_multipleCalls_emitsMultipleToolCallEvents() {
        var parser = LlamaToolCallParser()
        let input = """
        <tool_call>{"name":"tool_a","arguments":{}}</tool_call>\
        <tool_call>{"name":"tool_b","arguments":{}}</tool_call>
        """
        let events = parser.process(input)
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].toolName, "tool_a")
        XCTAssertEqual(toolCalls[1].toolName, "tool_b")
    }

    // MARK: - Chunk safety

    func test_tagSplitAcrossChunks_parsesCorrectly() {
        var parser = LlamaToolCallParser()

        // Split "<|tool_call>" across two chunks.
        let events1 = parser.process("<|tool_")
        let events2 = parser.process("call>\ncall:ping{}\n<|end_of_turn>")
        let all = events1 + events2

        let toolCalls = all.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "ping")
    }

    func test_closeTagSplitAcrossChunks_parsesCorrectly() {
        var parser = LlamaToolCallParser()
        var all: [GenerationEvent] = []
        all += parser.process("<tool_call>{\"name\":\"foo\",\"arguments\":{}}</")
        all += parser.process("tool_call>")

        let toolCalls = all.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "foo")
    }

    func test_singleByteChunks_parsesCorrectly() {
        var parser = LlamaToolCallParser()
        let full = "<tool_call>{\"name\":\"byte_test\",\"arguments\":{}}</tool_call>"
        var all: [GenerationEvent] = []
        for char in full.unicodeScalars {
            all += parser.process(String(char))
        }
        all += parser.finalize()

        let toolCalls = all.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "byte_test")
    }

    // MARK: - Invalid / malformed input

    func test_invalidJSON_inJSONFallback_isDiscarded() {
        var parser = LlamaToolCallParser()
        let events = parser.process("<tool_call>this is not json</tool_call>")
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertTrue(toolCalls.isEmpty, "Malformed JSON should be discarded silently")
    }

    func test_missingNameField_inJSONFallback_isDiscarded() {
        var parser = LlamaToolCallParser()
        let events = parser.process("<tool_call>{\"arguments\":{}}</tool_call>")
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertTrue(toolCalls.isEmpty)
    }

    // MARK: - finalize

    func test_finalize_emitsRemainingPlainText() {
        var parser = LlamaToolCallParser()
        _ = parser.process("Hello ")
        let events = parser.finalize()
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t }
            return nil
        }
        XCTAssertFalse(tokens.joined().isEmpty, "finalize should emit any buffered plain text")
    }

    func test_finalize_discardsPartialToolCallBlock() {
        var parser = LlamaToolCallParser()
        _ = parser.process("<tool_call>{\"name\":\"partial\"")
        // No close tag — incomplete block.
        let events = parser.finalize()
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let tc) = event { return tc }
            return nil
        }
        XCTAssertTrue(toolCalls.isEmpty, "Incomplete tool-call block must be discarded on finalize")
    }

    func test_finalize_calledOnFreshParser_returnsEmpty() {
        var parser = LlamaToolCallParser()
        XCTAssertTrue(parser.finalize().isEmpty)
    }

    // MARK: - Tool call ID uniqueness

    func test_multipleToolCalls_haveDistinctIDs() {
        var parser = LlamaToolCallParser()
        let events = parser.process("""
        <tool_call>{"name":"a","arguments":{}}</tool_call>\
        <tool_call>{"name":"b","arguments":{}}</tool_call>
        """)
        let ids = events.compactMap { event -> String? in
            if case .toolCall(let tc) = event { return tc.id }
            return nil
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1], "Each tool call must receive a distinct ID")
    }
}
#endif

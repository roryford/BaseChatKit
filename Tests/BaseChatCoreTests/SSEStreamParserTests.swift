import XCTest
@testable import BaseChatCore

/// Tests for SSEStreamParser byte-stream parsing.
final class SSEStreamParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeByteStream(_ string: String) -> AsyncThrowingStream<UInt8, Error> {
        let bytes = Array(string.utf8)
        return AsyncThrowingStream { continuation in
            for byte in bytes {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    private func collect(_ string: String) async throws -> [String] {
        let stream = SSEStreamParser.parse(bytes: makeByteStream(string))
        var results: [String] = []
        for try await value in stream {
            results.append(value)
        }
        return results
    }

    // MARK: - Tests

    func test_parse_singleDataLine() async throws {
        let results = try await collect("data: hello\n\n")
        XCTAssertEqual(results, ["hello"])
    }

    func test_parse_multipleDataLines() async throws {
        let input = "data: first\n\ndata: second\n\ndata: third\n\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["first", "second", "third"])
    }

    func test_parse_doneStopsStream() async throws {
        let input = "data: hello\ndata: [DONE]\ndata: after\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["hello"],
                       "Should stop at [DONE] and not yield 'after'")
    }

    func test_parse_ignoresEventLines() async throws {
        let input = "event: message\ndata: payload\n\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["payload"])
    }

    func test_parse_ignoresBlankLines() async throws {
        let input = "\n\ndata: hello\n\n\n\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["hello"])
    }

    func test_parse_stripsWhitespace() async throws {
        let input = "data:  hello  \n\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["hello"])
    }

    func test_parse_emptyDataIgnored() async throws {
        let input = "data: \n\n"
        let results = try await collect(input)
        XCTAssertTrue(results.isEmpty, "Empty data payload should be ignored")
    }

    func test_parse_jsonPayload() async throws {
        let json = #"{"choices":[{"delta":{"content":"hi"}}]}"#
        let input = "data: \(json)\n\n"
        let results = try await collect(input)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first, json)
    }

    func test_parse_emptyInput() async throws {
        let results = try await collect("")
        XCTAssertTrue(results.isEmpty, "Empty input should yield nothing")
    }
}

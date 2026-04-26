import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatInference

final class MCPJSONRPCCodecTests: XCTestCase {
    func test_encodeDecodeRoundTripForRequest() throws {
        let codec = MCPJSONRPCCodec(maxMessageBytes: 1024, maxJSONNestingDepth: 8)
        let message = MCPJSONRPCMessage.request(
            id: .int(7),
            method: "tools/list",
            params: .object(["include": .array([.string("alpha")])])
        )

        let encoded = try codec.encode(message)
        let decoded = try codec.decode(encoded)

        XCTAssertEqual(decoded, message)
    }

    func test_decodeRejectsOversizedMessage() throws {
        let codec = MCPJSONRPCCodec(maxMessageBytes: 8, maxJSONNestingDepth: 8)
        let payload = Data("{\"jsonrpc\":\"2.0\"}".utf8)

        XCTAssertThrowsError(try codec.decode(payload)) { error in
            XCTAssertEqual(error as? MCPError, .oversizeMessage(payload.count))
        }
    }

    func test_decodeRejectsExcessiveNestingDepth() throws {
        let codec = MCPJSONRPCCodec(maxMessageBytes: 1024, maxJSONNestingDepth: 3)
        let payload = Data("{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":{\"a\":{\"b\":{\"c\":1}}}}".utf8)

        XCTAssertThrowsError(try codec.decode(payload)) { error in
            XCTAssertEqual(error as? MCPError, .malformedMetadata("JSON depth exceeded max of 3"))
        }
    }
}

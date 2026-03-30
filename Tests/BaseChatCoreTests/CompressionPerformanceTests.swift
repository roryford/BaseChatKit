import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

final class CompressionPerformanceTests: XCTestCase {

    private let compressor = ExtractiveCompressor()
    private let tokenizer = CharTokenizer()
    private static let messageContent = "This is a test message with realistic length to simulate a real conversation turn."
    private static let systemPrompt = "You are a helpful assistant."

    // MARK: - Helpers

    private func makeMessages(count: Int) -> [CompressibleMessage] {
        (0..<count).map { i in
            let role = i % 2 == 0 ? "user" : "assistant"
            return CompressibleMessage(id: UUID(), role: role, content: Self.messageContent)
        }
    }

    // MARK: - 100 CompressibleMessage instances

    func testPerf_compress_100messages() {
        let messages = makeMessages(count: 100)
        measure {
            let exp = expectation(description: "compress_100")
            Task {
                _ = await self.compressor.compress(
                    messages: messages,
                    systemPrompt: Self.systemPrompt,
                    contextSize: 2048,
                    tokenizer: self.tokenizer
                )
                exp.fulfill()
            }
            waitForExpectations(timeout: 10)
        }
    }

    // MARK: - 500 CompressibleMessage instances

    func testPerf_compress_500messages() {
        let messages = makeMessages(count: 500)
        measure {
            let exp = expectation(description: "compress_500")
            Task {
                _ = await self.compressor.compress(
                    messages: messages,
                    systemPrompt: Self.systemPrompt,
                    contextSize: 2048,
                    tokenizer: self.tokenizer
                )
                exp.fulfill()
            }
            waitForExpectations(timeout: 10)
        }
    }
}

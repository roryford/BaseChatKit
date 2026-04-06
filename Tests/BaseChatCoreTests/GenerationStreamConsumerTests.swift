import XCTest
@testable import BaseChatCore

final class GenerationStreamConsumerTests: XCTestCase {

    // MARK: - Token Events

    func test_tokenEvent_returnsAppendText() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.token("Hello"))
        // Sabotage check: returning .noOp instead of .appendText in the .token case causes this to fail
        XCTAssertEqual(action, .appendText("Hello"))
    }

    func test_multipleTokens_returnAppendTextEach() {
        var consumer = GenerationStreamConsumer()
        XCTAssertEqual(consumer.handle(.token("Hello")), .appendText("Hello"))
        XCTAssertEqual(consumer.handle(.token(" world")), .appendText(" world"))
    }

    // MARK: - Usage Events

    func test_usageEvent_returnsRecordUsage() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.usage(prompt: 10, completion: 5))
        // Sabotage check: returning .noOp instead of .recordUsage in the .usage case causes this to fail
        XCTAssertEqual(action, .recordUsage(prompt: 10, completion: 5))
    }

    // MARK: - Tool Call Events

    func test_toolCallEvent_returnsNoOp() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.toolCall(name: "search", arguments: "{}"))
        XCTAssertEqual(action, .noOp)
    }

    // MARK: - Loop Detection

    func test_shouldStopForLoop_returnsFalse_whenDisabled() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: false)
        let repeating = String(repeating: "abc ", count: 100)
        XCTAssertFalse(consumer.shouldStopForLoop(content: repeating))
    }

    func test_shouldStopForLoop_returnsFalse_whenContentTooShort() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        XCTAssertFalse(consumer.shouldStopForLoop(content: "short"))
    }

    func test_shouldStopForLoop_returnsFalse_forNormalContent() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        let normal = "The quick brown fox jumps over the lazy dog. This is a perfectly normal sentence that should not trigger any loop detection whatsoever."
        // Sabotage check: always returning true from shouldStopForLoop causes this to fail
        XCTAssertFalse(consumer.shouldStopForLoop(content: normal))
    }

    func test_shouldStopForLoop_returnsTrue_forRepetitiveContent() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        // RepetitionDetector.looksLikeLooping checks for actual repetition patterns.
        // Build a string that clearly loops by repeating a phrase many times.
        let repeating = String(repeating: "I am a fish. ", count: 50)
        // Sabotage check: disabling RepetitionDetector.looksLikeLooping causes this to fail
        XCTAssertTrue(consumer.shouldStopForLoop(content: repeating))
    }
}

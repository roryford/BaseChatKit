import XCTest
@testable import BaseChatCore

final class PromptTemplateTests: XCTestCase {

    // MARK: - ChatML

    func test_chatML_singleUserMessage() {
        let result = PromptTemplate.chatML.format(
            messages: [("user", "Hello")],
            systemPrompt: nil
        )

        XCTAssertTrue(result.contains("<|im_start|>user"), "Should contain user start tag")
        XCTAssertTrue(result.contains("Hello<|im_end|>"), "Should contain message with end tag")
        XCTAssertTrue(result.contains("<|im_start|>assistant"), "Should end with assistant start tag")
    }

    func test_chatML_withSystemPrompt() {
        let result = PromptTemplate.chatML.format(
            messages: [("user", "Hello")],
            systemPrompt: "You are helpful."
        )

        XCTAssertTrue(result.contains("<|im_start|>system"), "Should contain system start tag")
        XCTAssertTrue(result.contains("You are helpful.<|im_end|>"), "Should contain system prompt with end tag")
        XCTAssertTrue(result.contains("<|im_start|>user"), "Should contain user start tag")
    }

    func test_chatML_multipleMessages() {
        let result = PromptTemplate.chatML.format(
            messages: [
                ("user", "Hi"),
                ("assistant", "Hello!"),
                ("user", "How are you?")
            ],
            systemPrompt: nil
        )

        // All three messages should be wrapped.
        XCTAssertTrue(result.contains("<|im_start|>user\nHi<|im_end|>"), "First user message should be wrapped")
        XCTAssertTrue(result.contains("<|im_start|>assistant\nHello!<|im_end|>"), "Assistant message should be wrapped")
        XCTAssertTrue(result.contains("<|im_start|>user\nHow are you?<|im_end|>"), "Second user message should be wrapped")
        XCTAssertTrue(result.hasSuffix("<|im_start|>assistant\n"), "Should end with assistant start tag")
    }

    // MARK: - Llama 3

    func test_llama3_singleUserMessage() {
        let result = PromptTemplate.llama3.format(
            messages: [("user", "Hello")],
            systemPrompt: nil
        )

        XCTAssertTrue(result.contains("<|begin_of_text|>"), "Should start with begin_of_text")
        XCTAssertTrue(result.contains("<|start_header_id|>user<|end_header_id|>"), "Should contain user header")
        XCTAssertTrue(result.contains("Hello<|eot_id|>"), "Should contain message with eot_id")
        XCTAssertTrue(result.contains("<|start_header_id|>assistant<|end_header_id|>"), "Should end with assistant header")
    }

    func test_llama3_withSystemPrompt() {
        let result = PromptTemplate.llama3.format(
            messages: [("user", "Hello")],
            systemPrompt: "Be helpful."
        )

        XCTAssertTrue(result.contains("<|start_header_id|>system<|end_header_id|>"), "Should contain system header")
        XCTAssertTrue(result.contains("Be helpful.<|eot_id|>"), "Should contain system prompt with eot_id")
    }

    // MARK: - Mistral

    func test_mistral_singleUserMessage() {
        let result = PromptTemplate.mistral.format(
            messages: [("user", "Hello")],
            systemPrompt: nil
        )

        XCTAssertTrue(result.contains("[INST]"), "Should contain [INST] tag")
        XCTAssertTrue(result.contains("[/INST]"), "Should contain [/INST] tag")
        XCTAssertTrue(result.contains("Hello"), "Should contain the user message")
    }

    func test_mistral_withSystemPrompt() {
        let result = PromptTemplate.mistral.format(
            messages: [("user", "Hello")],
            systemPrompt: "Be concise."
        )

        // System prompt is prepended to the first user message.
        XCTAssertTrue(result.contains("Be concise."), "Should contain system prompt")
        XCTAssertTrue(result.contains("Hello"), "Should contain user message")
        XCTAssertTrue(result.contains("[INST]"), "Should contain [INST] tag")

        // Verify system prompt comes before user message within the [INST] block.
        if let instRange = result.range(of: "[INST]"),
           let endInstRange = result.range(of: "[/INST]") {
            let content = String(result[instRange.upperBound..<endInstRange.lowerBound])
            let systemIndex = content.range(of: "Be concise.")?.lowerBound
            let userIndex = content.range(of: "Hello")?.lowerBound
            XCTAssertNotNil(systemIndex, "System prompt should be in the INST block")
            XCTAssertNotNil(userIndex, "User message should be in the INST block")
            if let sIdx = systemIndex, let uIdx = userIndex {
                XCTAssertTrue(sIdx < uIdx, "System prompt should come before user message")
            }
        }
    }

    func test_mistral_multiTurn() {
        let result = PromptTemplate.mistral.format(
            messages: [
                ("user", "Hi"),
                ("assistant", "Hello!"),
                ("user", "Bye")
            ],
            systemPrompt: nil
        )

        // Should have two [INST] blocks for two user messages.
        let instCount = result.components(separatedBy: "[INST]").count - 1
        XCTAssertEqual(instCount, 2, "Should have two [INST] blocks for two user messages")

        // Assistant response should appear between the two blocks.
        XCTAssertTrue(result.contains("Hello!</s>"), "Assistant response should end with </s>")
        XCTAssertTrue(result.contains("[/INST]"), "Should contain [/INST] tags")
    }

    // MARK: - Alpaca

    func test_alpaca_singleUserMessage() {
        let result = PromptTemplate.alpaca.format(
            messages: [("user", "Hello")],
            systemPrompt: nil
        )

        XCTAssertTrue(result.contains("### Instruction:"), "Should contain Instruction section")
        XCTAssertTrue(result.contains("### Input:"), "Should contain Input section")
        XCTAssertTrue(result.contains("### Response:"), "Should contain Response section")
        XCTAssertTrue(result.contains("Hello"), "Should contain the user message")
    }

    func test_alpaca_usesLastUserMessage() {
        let result = PromptTemplate.alpaca.format(
            messages: [
                ("user", "First question"),
                ("assistant", "First answer"),
                ("user", "Second question")
            ],
            systemPrompt: nil
        )

        // Alpaca is single-turn: only the last user message should appear as input.
        XCTAssertTrue(result.contains("Second question"), "Should contain the last user message")
        XCTAssertTrue(result.contains("### Input:\nSecond question"), "Last user message should be in the Input section")
        // First question should NOT appear in the Input section.
        XCTAssertFalse(result.contains("### Input:\nFirst question"), "First user message should not be the Input")
    }

    // MARK: - Gemma

    func test_gemma_singleUserMessage() {
        let result = PromptTemplate.gemma.format(
            messages: [("user", "Hello")],
            systemPrompt: nil
        )

        XCTAssertTrue(result.contains("<start_of_turn>user"), "Should contain user start tag")
        XCTAssertTrue(result.contains("<end_of_turn>"), "Should contain end_of_turn tag")
        XCTAssertTrue(result.contains("<start_of_turn>model"), "Should end with model start tag")
        XCTAssertTrue(result.contains("Hello"), "Should contain the user message")
    }

    func test_gemma_withSystemPrompt() {
        let result = PromptTemplate.gemma.format(
            messages: [("user", "Hello")],
            systemPrompt: "Be creative."
        )

        // System prompt is prepended to first user message (same pattern as Mistral).
        XCTAssertTrue(result.contains("Be creative."), "Should contain system prompt")
        XCTAssertTrue(result.contains("Hello"), "Should contain user message")

        // Verify system prompt comes before user message within the user turn.
        if let turnStart = result.range(of: "<start_of_turn>user\n"),
           let turnEnd = result.range(of: "<end_of_turn>") {
            let content = String(result[turnStart.upperBound..<turnEnd.lowerBound])
            let systemIndex = content.range(of: "Be creative.")?.lowerBound
            let userIndex = content.range(of: "Hello")?.lowerBound
            XCTAssertNotNil(systemIndex, "System prompt should be in the user turn")
            XCTAssertNotNil(userIndex, "User message should be in the user turn")
            if let sIdx = systemIndex, let uIdx = userIndex {
                XCTAssertTrue(sIdx < uIdx, "System prompt should come before user message")
            }
        }
    }

    func test_gemma_multipleMessages() {
        let result = PromptTemplate.gemma.format(
            messages: [
                ("user", "Hi"),
                ("assistant", "Hello!"),
                ("user", "How are you?")
            ],
            systemPrompt: nil
        )

        // Both user messages should be wrapped.
        XCTAssertTrue(
            result.contains("<start_of_turn>user\nHi<end_of_turn>"),
            "First user message should be wrapped"
        )
        XCTAssertTrue(
            result.contains("<start_of_turn>model\nHello!<end_of_turn>"),
            "Assistant message should be wrapped with model tag"
        )
        XCTAssertTrue(
            result.contains("<start_of_turn>user\nHow are you?<end_of_turn>"),
            "Second user message should be wrapped"
        )
        XCTAssertTrue(
            result.hasSuffix("<start_of_turn>model\n"),
            "Should end with model start tag"
        )
    }

    // MARK: - Phi

    func test_phi_singleUserMessage() {
        let result = PromptTemplate.phi.format(
            messages: [("user", "Hello")],
            systemPrompt: nil
        )

        XCTAssertTrue(result.contains("<|user|>"), "Should contain user tag")
        XCTAssertTrue(result.contains("<|end|>"), "Should contain end tag")
        XCTAssertTrue(result.contains("<|assistant|>"), "Should end with assistant tag")
        XCTAssertTrue(result.contains("Hello"), "Should contain the user message")
    }

    func test_phi_withSystemPrompt() {
        let result = PromptTemplate.phi.format(
            messages: [("user", "Hello")],
            systemPrompt: "You are a bard."
        )

        XCTAssertTrue(result.contains("<|system|>"), "Should contain system tag")
        XCTAssertTrue(result.contains("You are a bard.<|end|>"), "Should contain system prompt with end tag")
        XCTAssertTrue(result.contains("<|user|>"), "Should contain user tag")
        XCTAssertTrue(result.contains("Hello<|end|>"), "Should contain user message with end tag")
        XCTAssertTrue(result.contains("<|assistant|>"), "Should end with assistant tag")

        // System block should come before user block.
        if let systemRange = result.range(of: "<|system|>"),
           let userRange = result.range(of: "<|user|>") {
            XCTAssertTrue(
                systemRange.lowerBound < userRange.lowerBound,
                "System block should come before user block"
            )
        }
    }

    func test_phi_multipleMessages() {
        let result = PromptTemplate.phi.format(
            messages: [
                ("user", "Hi"),
                ("assistant", "Hello!"),
                ("user", "Bye")
            ],
            systemPrompt: nil
        )

        XCTAssertTrue(
            result.contains("<|user|>\nHi<|end|>"),
            "First user message should be wrapped"
        )
        XCTAssertTrue(
            result.contains("<|assistant|>\nHello!<|end|>"),
            "Assistant message should be wrapped"
        )
        XCTAssertTrue(
            result.contains("<|user|>\nBye<|end|>"),
            "Second user message should be wrapped"
        )
        XCTAssertTrue(
            result.hasSuffix("<|assistant|>\n"),
            "Should end with assistant tag and newline"
        )

        // Should have two user blocks.
        let userCount = result.components(separatedBy: "<|user|>").count - 1
        XCTAssertEqual(userCount, 2, "Should have two user blocks for two user messages")
    }
}

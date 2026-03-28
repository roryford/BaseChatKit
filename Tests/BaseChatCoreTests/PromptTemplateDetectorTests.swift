import XCTest
@testable import BaseChatCore

final class PromptTemplateDetectorTests: XCTestCase {

    // MARK: - Chat Template String Detection

    func test_detect_chatMLTemplate() {
        let template = "{% if messages[0] %}<|im_start|>system\n{{ content }}<|im_end|>{% endif %}"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .chatML)
    }

    func test_detect_llama3Template() {
        let template = "<|begin_of_text|><|start_header_id|>system<|end_header_id|>{{ content }}<|eot_id|>"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .llama3)
    }

    func test_detect_mistralTemplate() {
        let template = "{{ bos_token }}{% for message in messages %}[INST] {{ message['content'] }} [/INST]{% endfor %}"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .mistral)
    }

    func test_detect_gemmaTemplate() {
        let template = "<start_of_turn>user\n{{ content }}<end_of_turn>\n<start_of_turn>model"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .gemma)
    }

    func test_detect_phiTemplate() {
        let template = "<|system|>\n{{ system }}<|end|>\n<|user|>\n{{ content }}<|end|>\n<|assistant|>"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .phi)
    }

    func test_detect_alpacaTemplate() {
        let template = "### Instruction:\n{{ instruction }}\n\n### Input:\n{{ input }}\n\n### Response:"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .alpaca)
    }

    func test_detect_unknownTemplate_defaultsChatML() {
        let template = "some completely unknown template format"
        XCTAssertEqual(PromptTemplateDetector.detect(fromChatTemplate: template), .chatML)
    }

    // MARK: - Architecture Detection

    func test_detect_fromArchitecture_llama() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "llama"), .llama3)
    }

    func test_detect_fromArchitecture_mistral() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "mistral"), .mistral)
    }

    func test_detect_fromArchitecture_gemma() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "gemma"), .gemma)
    }

    func test_detect_fromArchitecture_gemma2() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "gemma2"), .gemma)
    }

    func test_detect_fromArchitecture_phi() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "phi"), .phi)
    }

    func test_detect_fromArchitecture_phi3() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "phi3"), .phi)
    }

    func test_detect_fromArchitecture_unknown_defaultsChatML() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "mamba"), .chatML)
    }

    func test_detect_fromArchitecture_caseInsensitive() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "Llama"), .llama3)
        XCTAssertEqual(PromptTemplateDetector.detect(fromArchitecture: "MISTRAL"), .mistral)
    }

    // MARK: - Filename Heuristic

    func test_detect_fromFileName_containsLlama() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "Meta-Llama-3-8B-Q4.gguf"), .llama3)
    }

    func test_detect_fromFileName_containsMistral() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "mistral-7b-instruct-v0.2.gguf"), .mistral)
    }

    func test_detect_fromFileName_containsGemma() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "gemma-2-2b-it.gguf"), .gemma)
    }

    func test_detect_fromFileName_containsPhi() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "Phi-3-mini-4k-instruct.gguf"), .phi)
    }

    func test_detect_fromFileName_containsAlpaca() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "alpaca-7b.gguf"), .alpaca)
    }

    func test_detect_fromFileName_unknown_defaultsChatML() {
        XCTAssertEqual(PromptTemplateDetector.detect(fromFileName: "some-random-model.gguf"), .chatML)
    }

    // MARK: - Full Metadata Detection (Cascading Priority)

    func test_detect_fromMetadata_prefersChatTemplate() {
        // Even with architecture = "llama", a ChatML template should win
        let metadata = GGUFMetadata(
            generalName: "Mistral-7B",
            generalArchitecture: "llama",
            contextLength: 4096,
            chatTemplate: "<|im_start|>system\n{{ content }}<|im_end|>",
            fileType: nil
        )

        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .chatML)
    }

    func test_detect_fromMetadata_fallsBackToArchitecture() {
        let metadata = GGUFMetadata(
            generalName: "SomeModel",
            generalArchitecture: "mistral",
            contextLength: 4096,
            chatTemplate: nil,
            fileType: nil
        )

        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .mistral)
    }

    func test_detect_fromMetadata_fallsBackToName() {
        let metadata = GGUFMetadata(
            generalName: "gemma-2b-it",
            generalArchitecture: nil,
            contextLength: nil,
            chatTemplate: nil,
            fileType: nil
        )

        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .gemma)
    }

    func test_detect_fromMetadata_noInfo_defaultsChatML() {
        let metadata = GGUFMetadata(
            generalName: nil,
            generalArchitecture: nil,
            contextLength: nil,
            chatTemplate: nil,
            fileType: nil
        )

        XCTAssertEqual(PromptTemplateDetector.detect(from: metadata), .chatML)
    }
}

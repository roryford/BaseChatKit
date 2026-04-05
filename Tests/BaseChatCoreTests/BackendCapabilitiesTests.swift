import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

final class BackendCapabilitiesTests: XCTestCase {

    // MARK: - Mock Backend Configurable Capabilities
    // NOTE: LlamaBackend, MLXBackend, and FoundationBackend live in BaseChatBackends.
    // Tests that require those concrete backends belong in BaseChatBackendsTests.
    // Here we verify the BackendCapabilities type and MockInferenceBackend wiring.

    func test_mockBackend_configurableCapabilities() {
        let customCaps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 2048,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false
        )

        let mock = MockInferenceBackend(capabilities: customCaps)

        XCTAssertEqual(mock.capabilities.maxContextTokens, 2048, "Should use custom context tokens")
        XCTAssertTrue(mock.capabilities.requiresPromptTemplate, "Should use custom requiresPromptTemplate")
        XCTAssertFalse(mock.capabilities.supportsSystemPrompt, "Should use custom supportsSystemPrompt")
        XCTAssertEqual(mock.capabilities.supportedParameters, [.temperature], "Should only support temperature")
    }

    func test_backendCapabilities_defaultValues() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )

        XCTAssertFalse(caps.requiresPromptTemplate)
        XCTAssertTrue(caps.supportsSystemPrompt)
        XCTAssertEqual(caps.maxContextTokens, 4096)
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
        XCTAssertTrue(caps.supportedParameters.contains(.repeatPenalty))
    }

    func test_backendCapabilities_emptyParameters() {
        let caps = BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 512,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false
        )

        XCTAssertTrue(caps.supportedParameters.isEmpty)
        XCTAssertEqual(caps.maxContextTokens, 512)
    }

    // MARK: - New Fields Defaults (old initializer)

    func test_oldInitializer_defaultsNewFieldsToFalseAndCooperative() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 2048,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )

        XCTAssertFalse(caps.supportsToolCalling)
        XCTAssertFalse(caps.supportsStructuredOutput)
        XCTAssertEqual(caps.cancellationStyle, .cooperative)
        XCTAssertFalse(caps.supportsTokenCounting)
    }

    // MARK: - Full Initializer

    func test_fullInitializer_setsAllFields() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 128_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            cancellationStyle: .explicit,
            supportsTokenCounting: true
        )

        XCTAssertEqual(caps.supportedParameters, [.temperature, .topP])
        XCTAssertEqual(caps.maxContextTokens, 128_000)
        XCTAssertFalse(caps.requiresPromptTemplate)
        XCTAssertTrue(caps.supportsSystemPrompt)
        XCTAssertTrue(caps.supportsToolCalling)
        XCTAssertTrue(caps.supportsStructuredOutput)
        XCTAssertEqual(caps.cancellationStyle, .explicit)
        XCTAssertTrue(caps.supportsTokenCounting)
    }

    // MARK: - MemoryStrategy

    func test_oldInitializer_defaultsMemoryStrategyToResident() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 2048,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )
        XCTAssertEqual(caps.memoryStrategy, .resident)
    }

    func test_fullInitializer_defaultsMemoryStrategyToResident() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 2048,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )
        XCTAssertEqual(caps.memoryStrategy, .resident)
    }

    func test_fullInitializer_setsMemoryStrategy() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 2048,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external
        )
        XCTAssertEqual(caps.memoryStrategy, .external)
    }

    func test_memoryStrategy_allCasesAreDistinct() {
        let resident = MemoryStrategy.resident
        let mappable = MemoryStrategy.mappable
        let external = MemoryStrategy.external

        XCTAssertNotEqual(resident, mappable)
        XCTAssertNotEqual(resident, external)
        XCTAssertNotEqual(mappable, external)
    }

    // MARK: - CancellationStyle

    func test_cancellationStyle_cooperativeAndExplicitAreDistinct() {
        let cooperative = CancellationStyle.cooperative
        let explicit = CancellationStyle.explicit

        // Swift enums without associated values are Equatable by default
        XCTAssertNotEqual(cooperative, explicit)
    }

    // MARK: - visibleParameters

    func test_visibleParameters_returnsFilteredInAllCasesOrder() {
        let caps = BackendCapabilities(
            supportedParameters: [.topP, .temperature, .topK],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )

        let visible = caps.visibleParameters

        // Should follow GenerationParameter.allCases order, filtered to supported
        XCTAssertEqual(visible, [.temperature, .topP, .topK])
    }

    func test_visibleParameters_emptyWhenNoParametersSupported() {
        let caps = BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 512,
            requiresPromptTemplate: false,
            supportsSystemPrompt: false
        )

        XCTAssertTrue(caps.visibleParameters.isEmpty)
    }

    func test_visibleParameters_allParametersWhenAllSupported() {
        let caps = BackendCapabilities(
            supportedParameters: Set(GenerationParameter.allCases),
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )

        XCTAssertEqual(caps.visibleParameters, GenerationParameter.allCases)
    }

    // MARK: - contextWindowSize, maxOutputTokens, supportsStreaming, isRemote

    func test_contextWindowSize_derivesFromMaxContextTokens() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 32_768,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )
        XCTAssertEqual(caps.contextWindowSize, 32_768)
    }

    func test_shortInitializer_defaultsNewFields() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )
        XCTAssertEqual(caps.maxOutputTokens, 4096)
        XCTAssertTrue(caps.supportsStreaming)
        XCTAssertFalse(caps.isRemote)
    }

    func test_fullInitializer_setsNewFields() {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 200_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 8192,
            supportsStreaming: true,
            isRemote: true
        )
        XCTAssertEqual(caps.contextWindowSize, 200_000)
        XCTAssertEqual(caps.maxOutputTokens, 8192)
        XCTAssertTrue(caps.supportsStreaming)
        XCTAssertTrue(caps.isRemote)
    }

    func test_fullInitializer_newFieldsDefaultValues() {
        let caps = BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )
        XCTAssertEqual(caps.maxOutputTokens, 4096)
        XCTAssertTrue(caps.supportsStreaming)
        XCTAssertFalse(caps.isRemote)
    }

    // MARK: - Codable round-trip

    func test_codable_roundTrip() throws {
        let original = BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 128_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 16_384,
            supportsStreaming: true,
            isRemote: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BackendCapabilities.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.contextWindowSize, 128_000)
        XCTAssertEqual(decoded.maxOutputTokens, 16_384)
        XCTAssertTrue(decoded.supportsStreaming)
        XCTAssertTrue(decoded.isRemote)
    }

    func test_codable_roundTrip_allMemoryStrategies() throws {
        for strategy in [MemoryStrategy.resident, .mappable, .external] {
            let caps = BackendCapabilities(
                supportedParameters: [],
                maxContextTokens: 4096,
                requiresPromptTemplate: false,
                supportsSystemPrompt: false,
                supportsToolCalling: false,
                supportsStructuredOutput: false,
                cancellationStyle: .cooperative,
                supportsTokenCounting: false,
                memoryStrategy: strategy
            )
            let data = try JSONEncoder().encode(caps)
            let decoded = try JSONDecoder().decode(BackendCapabilities.self, from: data)
            XCTAssertEqual(decoded.memoryStrategy, strategy)
        }
    }

    // MARK: - PromptAssembler reads contextWindowSize from capabilities

    func test_promptAssembler_capabilities_overload_usesContextWindowSize() {
        struct CharTok: TokenizerProvider { func tokenCount(_ t: String) -> Int { t.count } }
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 100,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )
        let messages = (0..<5).map { _ in
            ChatMessageRecord(role: .user, content: String(repeating: "x", count: 10), sessionID: UUID())
        }

        let result = PromptAssembler.assemble(
            slots: [],
            messages: messages,
            systemPrompt: nil,
            capabilities: caps,
            responseBuffer: 0,
            tokenizer: CharTok()
        )

        // contextWindowSize == 100, 5 messages x 10 chars = 50 tokens, all fit
        XCTAssertEqual(result.messages.count, 5)
        XCTAssertEqual(result.totalTokens, 50)
    }

    func test_promptAssembler_capabilities_overload_trimsWhenContextSmall() {
        struct CharTok: TokenizerProvider { func tokenCount(_ t: String) -> Int { t.count } }
        let caps = BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 30,
            requiresPromptTemplate: false,
            supportsSystemPrompt: false
        )
        let messages = (0..<5).map { _ in
            ChatMessageRecord(role: .user, content: String(repeating: "x", count: 10), sessionID: UUID())
        }

        let result = PromptAssembler.assemble(
            slots: [],
            messages: messages,
            systemPrompt: nil,
            capabilities: caps,
            responseBuffer: 0,
            tokenizer: CharTok()
        )

        // 30 tokens / 10 per message = 3 messages fit
        XCTAssertEqual(result.messages.count, 3)
    }
}

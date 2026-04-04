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
}

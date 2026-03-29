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
}

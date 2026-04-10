import XCTest
import BaseChatCore
import BaseChatTestSupport
@testable import BaseChatBackends

/// Contract tests that lock down capability fields on every concrete backend.
///
/// These tests exist to catch merge conflicts or accidental regressions where
/// capability flags are removed or flipped. If a test here fails, the backend's
/// declared posture has changed — update it deliberately.
final class BackendCapabilitiesContractTests: XCTestCase {

    // MARK: - Remote backends

    func test_cloudBackends_reportIsRemote() {
        XCTAssertTrue(ClaudeBackend().capabilities.isRemote,
                      "ClaudeBackend makes network calls — isRemote must be true")
        XCTAssertTrue(OpenAIBackend().capabilities.isRemote,
                      "OpenAIBackend makes network calls — isRemote must be true")
        XCTAssertTrue(OllamaBackend().capabilities.isRemote,
                      "OllamaBackend makes network calls — isRemote must be true")
    }

    // MARK: - Tool Calling

    func test_cloudBackends_toolCallingCapabilities() {
        // Tool calling was removed from BCK ahead of the 0.6.0 API freeze.
        // Every backend must report `false` until a stable cross-backend
        // contract is reintroduced. The capability flag itself is kept
        // (separate breaking change) so consumers that branch on it
        // continue to compile.
        XCTAssertFalse(ClaudeBackend().capabilities.supportsToolCalling,
                       "ClaudeBackend no longer advertises tool calling — the public API was removed")
        XCTAssertFalse(OpenAIBackend().capabilities.supportsToolCalling,
                       "OpenAIBackend no longer advertises tool calling — the public API was removed")
        XCTAssertFalse(OllamaBackend().capabilities.supportsToolCalling,
                       "OllamaBackend does not support tool calling")
    }

    func test_cloudBackends_structuredOutputCapabilities() {
        XCTAssertTrue(ClaudeBackend().capabilities.supportsStructuredOutput,
                      "ClaudeBackend supports structured output")
        XCTAssertTrue(OpenAIBackend().capabilities.supportsStructuredOutput,
                      "OpenAIBackend supports structured output via json_schema")
    }

    // MARK: - Local backends

#if Llama
    func test_llamaBackend_reportNotRemote() throws {
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
        XCTAssertFalse(LlamaBackend().capabilities.isRemote,
                       "LlamaBackend runs on-device — isRemote must be false")
    }

    func test_llamaBackend_doesNotSupportToolCalling() throws {
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
        XCTAssertFalse(LlamaBackend().capabilities.supportsToolCalling,
                       "LlamaBackend does not support tool calling natively")
    }
#endif

#if MLX
    func test_mlxBackend_reportNotRemote() throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "MLXBackend requires Apple Silicon")
        XCTAssertFalse(MLXBackend().capabilities.isRemote,
                       "MLXBackend runs on-device — isRemote must be false")
    }
#endif

#if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_reportNotRemote() {
        XCTAssertFalse(FoundationBackend().capabilities.isRemote,
                       "FoundationBackend uses OS-managed on-device models — isRemote must be false")
    }

    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_doesNotSupportToolCalling() {
        XCTAssertFalse(FoundationBackend().capabilities.supportsToolCalling,
                       "FoundationBackend does not expose tool calling in this version")
    }
#endif
}

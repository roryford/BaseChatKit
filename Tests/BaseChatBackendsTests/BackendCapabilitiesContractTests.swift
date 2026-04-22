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
        // Ollama advertises tool calling since Wave 2 dispatch wiring (PR #640)
        // — it emits OpenAI-compatible `tool_calls` over NDJSON and the
        // orchestrator loop in GenerationCoordinator dispatches them. Claude
        // and OpenAI backends remain without tool calling until their
        // per-vendor wire-format work lands (tracked under #435).
        XCTAssertFalse(ClaudeBackend().capabilities.supportsToolCalling,
                       "ClaudeBackend tool calling wiring is tracked under #435")
        XCTAssertFalse(OpenAIBackend().capabilities.supportsToolCalling,
                       "OpenAIBackend tool calling wiring is tracked under #435")
        XCTAssertTrue(OllamaBackend().capabilities.supportsToolCalling,
                      "OllamaBackend advertises tool calling since Wave 2 dispatch wiring")
    }

    func test_cloudBackends_structuredOutputCapabilities() {
        XCTAssertTrue(ClaudeBackend().capabilities.supportsStructuredOutput,
                      "ClaudeBackend supports structured output")
        XCTAssertTrue(OpenAIBackend().capabilities.supportsStructuredOutput,
                      "OpenAIBackend supports structured output via json_schema")
    }

    func test_backends_nativeJSONModeCapabilities() {
        XCTAssertFalse(ClaudeBackend().capabilities.supportsNativeJSONMode,
                       "ClaudeBackend does not advertise a dedicated native JSON mode")
        XCTAssertTrue(OpenAIBackend().capabilities.supportsNativeJSONMode,
                      "OpenAIBackend supports response_format json_object")
        XCTAssertTrue(OllamaBackend().capabilities.supportsNativeJSONMode,
                      "OllamaBackend supports format=json")
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

    func test_llamaBackend_doesNotSupportNativeJSONMode() throws {
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
        XCTAssertFalse(LlamaBackend().capabilities.supportsNativeJSONMode,
                       "LlamaBackend does not expose a native JSON mode")
    }
#endif

#if MLX
    func test_mlxBackend_reportNotRemote() throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "MLXBackend requires Apple Silicon")
        XCTAssertFalse(MLXBackend().capabilities.isRemote,
                       "MLXBackend runs on-device — isRemote must be false")
        XCTAssertFalse(MLXBackend().capabilities.supportsNativeJSONMode,
                       "MLXBackend does not expose a native JSON mode")
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

    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_doesNotSupportNativeJSONMode() {
        XCTAssertFalse(FoundationBackend().capabilities.supportsNativeJSONMode,
                       "FoundationBackend does not expose a native JSON mode in this version")
    }
#endif
}

import XCTest
import BaseChatCore
@testable import BaseChatBackends

/// Contract tests that lock down the `isRemote` field on every concrete backend.
///
/// These tests exist to catch merge conflicts or accidental regressions where
/// `isRemote` is removed or flipped. If a test here fails, the backend's
/// declared network posture has changed — update it deliberately.
final class BackendCapabilitiesContractTests: XCTestCase {

    // MARK: - Remote backends

    func test_cloudBackends_reportIsRemote() {
        XCTAssertTrue(ClaudeBackend().capabilities.isRemote,
                      "ClaudeBackend makes network calls — isRemote must be true")
        XCTAssertTrue(OpenAIBackend().capabilities.isRemote,
                      "OpenAIBackend makes network calls — isRemote must be true")
        XCTAssertTrue(OllamaBackend().capabilities.isRemote,
                      "OllamaBackend makes network calls — isRemote must be true")
        XCTAssertTrue(KoboldCppBackend().capabilities.isRemote,
                      "KoboldCppBackend makes network calls — isRemote must be true")
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
#endif
}

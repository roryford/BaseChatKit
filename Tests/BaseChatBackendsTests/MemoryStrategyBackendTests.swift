import XCTest
@testable import BaseChatBackends
import BaseChatCore

final class MemoryStrategyBackendTests: XCTestCase {

    // MARK: - Cloud Backends (no hardware needed)

    func test_openAIBackend_declaresExternalStrategy() {
        let backend = OpenAIBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .external)
    }

    func test_claudeBackend_declaresExternalStrategy() {
        let backend = ClaudeBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .external)
    }

    func test_koboldCppBackend_declaresExternalStrategy() {
        let backend = KoboldCppBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .external)
    }

    // MARK: - Local Backends (hardware gated)

    #if MLX
    func test_mlxBackend_declaresResidentStrategy() {
        let backend = MLXBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .resident)
    }
    #endif

    #if Llama
    func test_llamaBackend_declaresMappableStrategy() throws {
        try XCTSkipIf(true, "LlamaBackend requires global init -- tested manually on Apple Silicon")
    }
    #endif
}

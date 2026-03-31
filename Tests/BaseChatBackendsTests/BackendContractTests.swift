import XCTest
import BaseChatCore
@testable import BaseChatBackends

/// A protocol that backend test classes adopt to inherit a standard set of
/// contract tests every InferenceBackend implementation must satisfy.
///
/// Adopting types must implement `makeBackend()` returning a freshly
/// initialised, unconfigured backend instance.
protocol BackendContractSuite: XCTestCase {
    associatedtype Backend: InferenceBackend
    func makeBackend() -> Backend
}

extension BackendContractSuite {
    func test_contract_isNotLoadedOnInit() {
        XCTAssertFalse(makeBackend().isModelLoaded,
                       "Backend must report isModelLoaded == false before loadModel is called")
    }

    func test_contract_isNotGeneratingOnInit() {
        XCTAssertFalse(makeBackend().isGenerating,
                       "Backend must report isGenerating == false before any generation")
    }

    func test_contract_generateBeforeLoad_throws() {
        let backend = makeBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig()),
            "generate() must throw when called before loadModel()"
        )
    }

    func test_contract_capabilities_parametersNotEmpty() {
        XCTAssertFalse(makeBackend().capabilities.supportedParameters.isEmpty,
                       "Backend must advertise at least one supported generation parameter")
    }

    func test_contract_unloadModel_isIdempotent() {
        let backend = makeBackend()
        // Should not crash when called on an already-unloaded backend
        backend.unloadModel()
        backend.unloadModel()
    }

    func test_contract_stopGeneration_beforeLoad_doesNotCrash() {
        let backend = makeBackend()
        // Should be safe to call even without an active generation
        backend.stopGeneration()
    }
}

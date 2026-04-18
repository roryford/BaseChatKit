import Foundation
import BaseChatInference

/// A configurable fake implementation of `GenerationContextProvider` for tests.
///
/// `GenerationCoordinator` holds its provider as a `weak var`, so tests that
/// need to exercise the coordinator directly must supply an object they own
/// for its lifetime. This fake lives in `BaseChatTestSupport` (rather than
/// each test target) so every inference-level test can construct the
/// `GenerationCoordinator` → provider graph without duplicating boilerplate
/// or reaching for `@testable import`.
///
/// `backend` is a concrete `MockInferenceBackend` so tests can configure
/// tokens, injected errors, and stop/generate call counts exactly as they do
/// for any other mock-backend-based test.
@MainActor
public final class FakeGenerationContextProvider: GenerationContextProvider {

    /// The mock backend served as `currentBackend`.
    ///
    /// Exposed directly (rather than wrapped) so tests can inspect and mutate
    /// its state — configure token streams, set `shouldThrowOnGenerate`,
    /// assert on `generateCallCount`, etc.
    public let backend: MockInferenceBackend

    /// Overrides the protocol's `selectedPromptTemplate` read. Defaults to
    /// `.chatML` which matches the coordinator's fallback when no template
    /// is explicitly chosen.
    public var promptTemplate: PromptTemplate = .chatML

    public init(backend: MockInferenceBackend = MockInferenceBackend()) {
        self.backend = backend
        // Default to a "loaded" state so enqueue() passes its guard. Tests
        // that want the unloaded path flip this explicitly.
        self.backend.isModelLoaded = true
    }

    // MARK: - GenerationContextProvider

    public var currentBackend: (any InferenceBackend)? { backend }

    public var isBackendLoaded: Bool { backend.isModelLoaded }

    public var selectedPromptTemplate: PromptTemplate { promptTemplate }
}

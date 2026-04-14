@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests that `ChatViewModel`'s per-message token count cache is invalidated at
/// the correct moments so stale counts from a previous tokenizer (or previous
/// edit content) cannot leak back into ``ChatViewModel/updateContextEstimate()``.
@MainActor
final class ChatViewModelCacheLifecycleTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeViewModel(
        handler: MemoryPressureHandler = MemoryPressureHandler(),
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend, MemoryPressureHandler) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "CacheLifecycleMock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: handler
        )
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        let session = ChatSession(title: "Cache Lifecycle")
        context.insert(session)
        try? context.save()
        vm.switchToSession(session.toRecord())
        return (vm, mock, handler)
    }

    // MARK: - Bug 1: unloadModel clears the token cache

    /// A populated `tokenCountCache` must be cleared by `unloadModel()` so that
    /// counts computed with the old tokenizer are not returned after a later
    /// model swap picks up the same message UUIDs.
    func test_unloadModel_clearsTokenCountCache() async {
        let (vm, _, _) = makeViewModel()

        // Populate the cache by sending a message.
        vm.inputText = "Cache population"
        await vm.sendMessage()

        XCTAssertFalse(vm.tokenCountCache.isEmpty,
            "Precondition: cache should be populated after sending a message")

        // Act: unload.
        vm.unloadModel()

        // Assert: cache is empty.
        XCTAssertTrue(vm.tokenCountCache.isEmpty,
            "tokenCountCache must be cleared by unloadModel() to prevent stale counts after a model swap")
    }

    /// Memory-pressure-driven unload (the primary motivating scenario) must
    /// also clear the cache, not just manual unloads.
    func test_memoryPressureCritical_clearsTokenCountCache() async {
        let handler = MemoryPressureHandler()
        let (vm, _, _) = makeViewModel(handler: handler)

        vm.inputText = "Memory pressure cache test"
        await vm.sendMessage()

        XCTAssertFalse(vm.tokenCountCache.isEmpty,
            "Precondition: cache should be populated after sending a message")

        // Simulate an OS critical memory pressure event.
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        XCTAssertTrue(vm.tokenCountCache.isEmpty,
            "tokenCountCache must be cleared when memory pressure triggers an unload")
    }

    // MARK: - Bug 2: edited message cache entry is invalidated

    /// `editMessage()` keeps the same UUID but changes the content; any cached
    /// token count for that UUID must be dropped so the next
    /// `updateContextEstimate()` recomputes for the new content.
    func test_editMessage_invalidatesTokenCacheEntry() async {
        let (vm, mock, _) = makeViewModel()

        // Send a user message and wait for the assistant reply.
        mock.tokensToYield = ["Hi"]
        vm.inputText = "x"                 // 1 char → heuristic yields 1 token
        await vm.sendMessage()

        let userID = vm.messages[0].id
        XCTAssertEqual(vm.tokenCountCache[userID], 1,
            "Precondition: short user message should cache as 1 token")
        let tokensBeforeEdit = vm.contextUsedTokens

        // Edit the user message to much longer content. The edit blocks on
        // regeneration (new assistant stream), so await it in full.
        mock.tokensToYield = ["Edited reply"]
        let longerContent = String(repeating: "a", count: 80) // 80 chars → 20 tokens
        await vm.editMessage(userID, newContent: longerContent)

        // The cache entry for the edited UUID must reflect the new content,
        // not the stale 1-token count from the original "x" text.
        let cachedAfterEdit = vm.tokenCountCache[userID]
        XCTAssertEqual(cachedAfterEdit, 20,
            "Edited message's cache entry must reflect the new content (80 chars → 20 tokens), not the stale count")
        XCTAssertGreaterThan(vm.contextUsedTokens, tokensBeforeEdit,
            "Context estimate must grow to reflect the longer edited content")
    }

    // MARK: - Bug 3: struct tokenizer identity discrimination

    /// When the backend vends a value-type (struct) tokenizer, the identity
    /// discriminator in ``ChatViewModel/reusableCachingTokenizer`` must use
    /// `type(of:) is AnyClass` — not `as? AnyObject`, which always succeeds on
    /// protocol existentials and defeats the value-type fallback branch.
    /// Verifies the computed property round-trips a struct tokenizer without
    /// crashing and reuses the same cached instance on subsequent calls.
    func test_reusableCachingTokenizer_stableIdentity_forStructTokenizer() async {
        let backend = StructTokenizerVendorBackend()
        let service = InferenceService(backend: backend, name: "StructVendor")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        // Precondition: the backend must actually vend a struct tokenizer, so we
        // exercise the value-type branch of the identity discriminator.
        let resolved = service.tokenizer
        XCTAssertNotNil(resolved, "Fixture must vend a tokenizer")
        if let resolved {
            XCTAssertFalse(type(of: resolved) is AnyClass,
                "Fixture must vend a value-type tokenizer to exercise the struct branch")
        }

        // Two consecutive accesses must return the same cached instance: if the
        // identity discriminator boxes a struct into a fresh AnyObject each call,
        // ObjectIdentifier differs every time, forcing a new CachingTokenizer on
        // every access and defeating the whole cache.
        let first = vm.reusableCachingTokenizer
        let second = vm.reusableCachingTokenizer
        XCTAssertTrue(first === second,
            "reusableCachingTokenizer must return the same cached instance across calls when the backend tokenizer identity hasn't changed")
    }
}

// MARK: - Test Fixtures

/// Backend that vends a struct-based tokenizer. Exercises the value-type branch
/// of the identity discriminator in ``ChatViewModel/reusableCachingTokenizer``.
private struct StubStructTokenizer: TokenizerProvider {
    func tokenCount(_ text: String) -> Int { max(1, text.count / 4) }
}

private final class StructTokenizerVendorBackend: InferenceBackend, TokenizerVendor, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 2048,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var tokenizer: any TokenizerProvider { StubStructTokenizer() }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }
}

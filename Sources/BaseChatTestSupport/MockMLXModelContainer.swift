#if MLX
import Foundation
import MLXLMCommon

// MARK: - SendableLMInput

/// Wraps the non-Sendable `LMInput` so it can be passed across concurrency boundaries.
///
/// This is `@unchecked Sendable` because `LMInput` holds `MLXArray` values that are not
/// marked `Sendable`. The wrapper is safe when access to the underlying value is
/// serialised — e.g. produced and consumed within the same `Task`.
public struct SendableLMInput: @unchecked Sendable {
    public let value: LMInput

    public init(_ value: LMInput) {
        self.value = value
    }
}

// MARK: - MockMLXModelContainer

/// Fake model container for unit-testing `MLXBackend` generation without hardware.
///
/// Conforms to `MLXModelContainerProtocol` via an extension declared in
/// `BaseChatBackendsTests` (where the internal protocol is visible). This avoids
/// importing `BaseChatBackends` from `BaseChatTestSupport`.
public final class MockMLXModelContainer: @unchecked Sendable {

    // MARK: - Configuration

    /// Tokens the mock yields from `generate`. Defaults to a two-token sequence.
    public var tokensToYield: [String] = ["Hello", " world"]

    /// When set, `generate` throws this error instead of yielding tokens.
    public var generateError: Error?

    // MARK: - Observation

    /// Number of times `generate(messages:parameters:)` was called.
    public private(set) var generateCallCount = 0

    /// Last messages passed to `generate`.
    public private(set) var lastMessages: [[String: String]]?

    public init() {}

    // MARK: - Protocol-shaped method (consumed by BaseChatBackendsTests conformance)

    public func generate(
        messages: [[String: String]],
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation> {
        generateCallCount += 1
        lastMessages = messages
        if let error = generateError { throw error }

        let tokens = tokensToYield
        return AsyncStream { continuation in
            let producerTask = Task {
                for token in tokens {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(.chunk(token))
                    await Task.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producerTask.cancel()
            }
        }
    }
}
#endif

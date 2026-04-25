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

    /// Simulates a chat-template / tokenizer rejection at `apply_chat_template` time.
    ///
    /// When set, `generate(messages:parameters:)` throws this error before yielding
    /// any token — modeling the failure mode where the loaded tokenizer either has
    /// no chat template (`tokenizer_config.json` missing the `chat_template` field)
    /// or the template rejects the supplied message set (e.g. missing
    /// `<|assistant|>` marker, wrong role ordering). The error surfaces unwrapped
    /// through `MLXBackend.generate`'s GenerationStream — see issue #551.
    public var simulatedTokenizerApplyFailure: Error?

    /// Optional stand-in for the tokenizer's `chat_template` field. The mock does
    /// NOT itself apply a Jinja template — production MLXModelContainer does that
    /// internally — but tests can set this to document which template shape they
    /// are exercising and assert the backend hands compatible messages along.
    public var simulatedChatTemplate: String?

    // MARK: - Observation

    /// Number of times `generate(messages:parameters:)` was called.
    public private(set) var generateCallCount = 0

    /// Last messages passed to `generate`.
    public private(set) var lastMessages: [[String: String]]?

    /// Last `GenerateParameters` value passed to `generate`. Useful for asserting
    /// that `MLXBackend` forwards `temperature` / `topP` / `topK` / `minP` /
    /// `repetitionPenalty` from the caller's `GenerationConfig`.
    public private(set) var lastParameters: GenerateParameters?

    public init() {}

    // MARK: - Protocol-shaped method (consumed by BaseChatBackendsTests conformance)

    public func generate(
        messages: [[String: String]],
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation> {
        generateCallCount += 1
        lastMessages = messages
        lastParameters = parameters
        // Tokenizer-apply failures throw before any token is yielded — that is
        // the failure mode `MLXBackend` sees when a template is missing or the
        // message set is rejected by the chat template.
        if let error = simulatedTokenizerApplyFailure { throw error }
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

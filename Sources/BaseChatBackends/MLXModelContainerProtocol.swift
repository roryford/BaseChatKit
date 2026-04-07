#if MLX
import MLXLMCommon

/// Abstraction over `ModelContainer` so `MLXBackend` can be tested without real hardware.
///
/// The single `generate` method encapsulates both input preparation and token streaming,
/// keeping the non-Sendable `LMInput` as an internal implementation detail of the
/// concrete `ModelContainer` conformance. This lets test mocks return token streams
/// without touching the Metal GPU stack.
protocol MLXModelContainerProtocol: Sendable {
    /// Prepares messages and generates a token stream.
    func generate(
        messages: [[String: String]],
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation>
}

// Make the real ModelContainer conform, handling prepare() internally.
extension ModelContainer: MLXModelContainerProtocol {
    func generate(
        messages: [[String: String]],
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation> {
        let input = try await prepare(input: .init(messages: messages))
        return try await generate(input: input, parameters: parameters, wiredMemoryTicket: nil)
    }
}
#endif

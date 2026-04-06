import BaseChatCore

/// A backend for any server that implements the OpenAI Chat Completions API.
///
/// Compatible with LM Studio, llama.cpp server (`--server`), vLLM, LocalAI,
/// Jan, and any other self-hosted server that speaks `/v1/chat/completions`.
///
/// This is a convenience alias for ``OpenAIBackend``. Both names refer to the
/// same implementation — use whichever name better reflects your intent at the
/// call site.
///
/// Local servers typically require no API key; pass `nil` for `apiKey`.
///
/// Usage:
/// ```swift
/// let backend = OpenAICompatibleBackend()
/// backend.configure(
///     baseURL: URL(string: "http://localhost:1234")!,
///     apiKey: nil,
///     modelName: "my-local-model"
/// )
/// try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await event in stream { if case .token(let t) = event { print(t, terminator: "") } }
/// ```
public typealias OpenAICompatibleBackend = OpenAIBackend

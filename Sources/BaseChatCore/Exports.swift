// Re-export `BaseChatInference` so existing consumers that `import BaseChatCore`
// continue to see all inference orchestration symbols (InferenceService, backend
// protocols, generation events, context window management, prompt templates,
// macros, repetition detection, tokenizers, capability API, etc.) without code
// changes after the BaseChatInference target was extracted.
//
// Apps can opt into the narrower `import BaseChatInference` at any time if they
// don't need BaseChatCore's SwiftData persistence layer.
@_exported import BaseChatInference

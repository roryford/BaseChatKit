# ``BaseChatInference``

Inference orchestration for BaseChatKit — protocols, models, and services that
coordinate model loading, generation, context budgeting, and prompt assembly.

## Overview

`BaseChatInference` contains the inference surface area of BaseChatKit:
``InferenceService`` and the `InferenceBackend` protocol family, generation
events and streams, context window management, prompt templates and assembly,
macro expansion, repetition detection, tokenizers, and the
capability/compatibility API.

It does **not** depend on SwiftData. Apps that need inference orchestration but
implement their own persistence and chat UI can depend on this target alone and
leave `BaseChatCore` (which contains the SwiftData schema and persistence
provider) out of their build graph.

For apps that want the full chat experience, `BaseChatCore` re-exports
`BaseChatInference` so a single `import BaseChatCore` brings in everything.

## Topics

### Configuration

- ``BaseChatConfiguration``

### Inference orchestration

- ``InferenceService``
- ``InferenceBackend``
- ``BackendCapabilities``

### Conversation records

- ``ChatMessageRecord``
- ``ChatSessionRecord``
- ``MessageRole``
- ``MessagePart``

### Generation

- ``GenerationEvent``
- ``GenerationStream``

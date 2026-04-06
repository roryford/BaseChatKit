# ``InferenceService``

## Topics

### State

- ``isModelLoaded``
- ``isGenerating``
- ``activeBackendName``
- ``capabilities``
- ``selectedPromptTemplate``
- ``lastTokenUsage``

### Loading Models

- ``loadModel(from:type:contextSize:)``
- ``loadCloudBackend(from:)``
- ``unloadModel()``
- ``resetConversation()``

### Generation

- ``generate(messages:systemPrompt:temperature:topP:repeatPenalty:maxOutputTokens:)``
- ``stopGeneration()``
- ``generationDidFinish()``

### Backend Registration

- ``registerBackendFactory(_:)``
- ``registerCloudBackendFactory(_:)``
- ``BackendFactory``
- ``CloudBackendFactory``

### Compatibility

- ``registeredBackendSnapshot()``

### Tool Calling

- ``toolProvider``
- ``toolCallObserver``

### Tokenization

- ``tokenizer``

### Memory Management

- ``memoryGate``

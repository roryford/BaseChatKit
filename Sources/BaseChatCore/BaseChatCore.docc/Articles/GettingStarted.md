# Getting Started with BaseChatCore

Configure BaseChatKit and wire up your first inference-backed chat session.

## Overview

This article walks you through the three steps needed to get BaseChatKit running in a new app:

1. Configure the framework at startup
2. Register backends
3. Create an `InferenceService` and begin generating

### Step 1 — Configure the framework

Set ``BaseChatConfiguration/shared`` once, as early as possible in your app's lifecycle (typically in your `@main` struct or `AppDelegate`):

```swift
import BaseChatCore
import BaseChatBackends

@main
struct MyApp: App {
    init() {
        BaseChatConfiguration.shared = BaseChatConfiguration(
            appName: "MyApp",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.example.myapp"
        )
    }

    var body: some Scene { ... }
}
```

Use ``BaseChatConfiguration/Features`` to disable UI features that don't apply to your deployment. For example, an offline-only app might disable cloud API management:

```swift
BaseChatConfiguration.shared = BaseChatConfiguration(
    appName: "MyApp",
    bundleIdentifier: "com.example.myapp",
    features: .init(
        showCloudAPIManagement: false,
        showServerDiscovery: false
    )
)
```

### Step 2 — Register backends

Backends live in `BaseChatBackends` and are registered against `InferenceService` via factory closures. This keeps `BaseChatCore` free of any dependency on MLX, llama.cpp, or Foundation Models — you only pull in the backends you need.

```swift
import BaseChatBackends

// Register all available backends in one call:
DefaultBackends.registerAll(with: inferenceService)

// Or register individually for more control:
inferenceService.registerBackendFactory { modelType in
    switch modelType {
    case .gguf: return LlamaBackend()
    case .mlx:  return MLXBackend()
    default:    return nil
    }
}

inferenceService.registerCloudBackendFactory { provider in
    switch provider {
    case .claude: return ClaudeBackend()
    case .openAI: return OpenAIBackend()
    default:      return OpenAICompatibleBackend(provider: provider)
    }
}
```

### Step 3 — Load a model and generate

```swift
let service = InferenceService()

// Load a GGUF model from disk
let modelURL = URL.documentsDirectory
    .appending(path: "Models/llama-3.2-3b-instruct.Q4_K_M.gguf")
try await service.loadModel(from: modelURL, type: .gguf, contextSize: 4096)

// Generate a response
let stream = try service.generate(
    messages: [ChatMessageRecord(role: .user, content: "Hello!")],
    config: GenerationConfig(temperature: 0.7)
)

for await event in stream.events {
    if case let .token(text) = event {
        print(text, terminator: "")
    }
}
```

## Sharing InferenceService across components

Create `InferenceService` once at the app level and inject it wherever you need generation. Do not create multiple instances — each instance manages its own backend lifecycle and they will step on each other.

```swift
// App level
let inference = InferenceService()
let chatVM = ChatViewModel(inferenceService: inference)
let storyStore = StoryStore(inferenceService: inference)  // your own type
```

See ``ChatViewModel`` in `BaseChatUI` for the primary consumer.

## Persistence

BaseChatKit persists sessions and messages through ``ChatPersistenceProvider``. The default implementation uses SwiftData. Create a ``ModelContainerFactory`` container and wire it to ``SwiftDataPersistenceProvider``:

```swift
let container = try ModelContainerFactory.makeContainer()
let persistence = SwiftDataPersistenceProvider(container: container)
chatViewModel.configure(persistence: persistence)
```

Use ``ModelContainerFactory/makeInMemoryContainer()`` in tests and SwiftUI previews.

## Next Steps

- See ``BaseChatConfiguration/Features`` for the full list of feature flags
- See ``GenerationConfig`` for sampling parameters (temperature, top-p, repeat penalty)
- See ``PromptTemplate`` for the supported chat formatting templates
- See ``ChatPersistenceProvider`` to implement a custom storage backend

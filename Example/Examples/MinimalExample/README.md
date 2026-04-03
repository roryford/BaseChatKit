# Minimal Example

The simplest possible BaseChatKit app. Demonstrates the bare minimum setup:

- Configure `BaseChatConfiguration` at startup
- Register backends with `DefaultBackends.register(with:)`
- Create a `ChatViewModel` and `SessionManagerViewModel`
- Set up SwiftData with `BaseChatSchema.allModelTypes`
- Present `ChatView` with environment wiring

## Running

1. Open `BaseChatExamples.xcodeproj` in Xcode
2. Select the **MinimalExample** scheme
3. Build and run on iOS Simulator or Mac

## What to Look At

- `MinimalExampleApp.swift` — app entry point and backend registration (~35 lines)
- `MinimalContentView.swift` — wraps `ChatView` with minimal onAppear setup

## Next Steps

See the other examples for specific features (narration, remote backends, tool calling, RAG).

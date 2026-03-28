# BaseChat Demo

Minimal example app showing how to build a chat interface with BaseChatKit.

## Running

1. Open the `BaseChatDemo.xcodeproj` in Xcode
2. The project references `BaseChatKit` as a local package from `../../`
3. Build and run on iOS Simulator or Mac

## What This Demonstrates

- Configuring `BaseChatConfiguration` at startup
- Composing `BaseChatUI` views (ChatView, SessionListView, ModelManagementSheet)
- Setting up SwiftData with `BaseChatSchema.allModelTypes`
- Wiring view models via `@Environment`

## Customization

To add your own backends, import `BaseChatBackends` and call:

```swift
DefaultBackends.register(with: chatViewModel.inferenceService)
```

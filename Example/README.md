# BaseChatKit Examples

## BaseChatDemo (Full Reference App)

The full-featured demo showing all BaseChatKit capabilities working together. This is also the host for UI tests.

1. Open `BaseChatDemo.xcodeproj` in Xcode
2. The project references `BaseChatKit` as a local package from `../../`
3. Build and run on iOS Simulator or Mac

### What This Demonstrates

- Configuring `BaseChatConfiguration` at startup
- Composing `BaseChatUI` views (ChatView, SessionListView, ModelManagementSheet)
- Setting up SwiftData with `BaseChatSchema.allModelTypes`
- Wiring view models via `@Environment`
- Cloud API endpoint management
- Multi-session chat with auto-rename
- Model download and storage management

## Focused Examples

Small, purpose-built apps that each showcase a single feature. Open `Examples/BaseChatExamples.xcodeproj` in Xcode and select the scheme for the example you want to run.

| Example | Scheme | What It Shows |
|---------|--------|---------------|
| [MinimalExample](Examples/MinimalExample/) | `MinimalExample_iOS` / `MinimalExample_macOS` | Bare-minimum BaseChatKit app (~40 lines) |
| [NarrationExample](Examples/NarrationExample/) | `NarrationExample_iOS` / `NarrationExample_macOS` | Text-to-speech narration with AVSpeechSynthesizer |

More examples ship alongside new features — see each example's README for details.

## Customization

To add your own backends, import `BaseChatBackends` and call:

```swift
DefaultBackends.register(with: chatViewModel.inferenceService)
```

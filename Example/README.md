# BaseChatKit Examples

## BaseChatDemo (Full Reference App)

The full-featured demo showing all BaseChatKit capabilities working together. This is also the host for UI tests.

1. Open `BaseChatDemo.xcodeproj` in Xcode
2. The project references `BaseChatKit` as a local package from `../../`
3. Build and run on iOS Simulator or Mac

### UI test debugging

From the repository root, use the fast rerun loop:

```bash
scripts/example-ui-tests.sh build-for-testing
scripts/example-ui-tests.sh test-without-building -only-testing:BaseChatDemoUITests/ChatFlowUITests/testEmptyStateShowsWelcome
```

The helper auto-selects an available simulator destination. If you need to pin one manually, inspect `xcrun simctl list devices available` and pass `--destination 'platform=iOS Simulator,id=<SIMULATOR_ID>'`.

### What This Demonstrates

- Configuring `BaseChatConfiguration` at startup
- Composing `BaseChatUI` views (ChatView, SessionListView, ModelManagementSheet)
- Setting up SwiftData with `ModelContainerFactory`
- Wiring view models via `@Environment`
- Cloud API endpoint management
- Multi-session chat with auto-rename
- Model download and storage management

## Focused Examples

Small, purpose-built apps that each showcase a single feature. Open `Examples/BaseChatExamples.xcodeproj` in Xcode and select the scheme for the example you want to run.

| Example | Scheme | What It Shows |
|---------|--------|---------------|
| [MinimalExample](Examples/MinimalExample/) | `MinimalExample_iOS` / `MinimalExample_macOS` | Bare-minimum BaseChatKit app (~40 lines) |

More examples ship alongside new features — see each example's README for details.

## Customization

To add your own backends, import `BaseChatBackends` and call:

```swift
DefaultBackends.register(with: chatViewModel.inferenceService)
```

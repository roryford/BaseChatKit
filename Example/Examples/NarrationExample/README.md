# Narration Example

Demonstrates BaseChatKit's text-to-speech narration feature using Apple's on-device `AVSpeechSynthesizer`.

## What This Shows

- Enabling narration via `BaseChatConfiguration.Features.showNarration`
- Creating and configuring a `NarrationViewModel` with `AVSpeechNarrationProvider`
- Injecting the narration view model into the environment
- Speaker buttons on assistant message bubbles for read-aloud
- Playback bar (pause/resume/stop) that appears during narration

## Running

1. Open `BaseChatExamples.xcodeproj` in Xcode
2. Select the **NarrationExample_iOS** or **NarrationExample_macOS** scheme
3. Build and run
4. Send a message, then tap the speaker icon on the assistant's response

## Key Code

- `NarrationExampleApp.swift` — app entry point, configures `NarrationViewModel` with `AVSpeechNarrationProvider`
- The narration UI (speaker buttons, playback bar) is built into `BaseChatUI` and activates when `showNarration` is `true` and a `NarrationViewModel` is in the environment

## Customization

To use a different TTS engine, implement `NarrationProvider` and pass it to `NarrationViewModel.configure(provider:)`:

```swift
let narration = NarrationViewModel()
narration.configure(provider: MyCustomTTSProvider())
```

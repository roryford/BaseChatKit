# Scope Decision — BCK 0.6.0

## Why we slimmed BCK

Consumer audits of BaseChatKit's two known consumers — Fireside and ChatbotUI-iOS — showed that less than half of the codebase had any real demand. Several large subsystems had zero consumers at all, and several more had a single consumer that used only a narrow slice of the public API. The April 2026 feature-expansion plan that introduced most of this surface area was built without this data, so 0.6.0 is the correction: we are deleting what nobody used and repositioning BCK around what actually makes it valuable to the apps that ship it.

## Consumer audit summary

| Capability | Fireside | ChatbotUI-iOS |
|---|---|---|
| `InferenceService` + `DefaultBackends` | transparent-use | transparent-use |
| `ChatViewModel` | ✓ | ✓ |
| `ChatView` (drop-in) | ✗ | ✓ |
| `SessionListView` (drop-in) | ✗ | ✓ |
| `ModelManagementSheet` | ✗ | ✓ |
| `APIConfigurationView` | ✗ | ✓ |
| HuggingFace downloader | ✗ | ✓ |
| Compression pipeline | ✓ | ✗ |
| Macro system (full) | ✓ | ✗ (uses only `macroContext.userName`) |
| Server discovery | ✗ | ✗ |
| Tool calling | ✗ | ✗ |

Fireside is the original home of the compression pipeline and uses the macro system to drive its `LorebookTriggerEngine`. ChatbotUI-iOS is the drop-in consumer — it takes the UI wholesale (`ChatView`, `SessionListView`, `ModelManagementSheet`, `APIConfigurationView`) plus the HuggingFace downloader, and touches macros only through `macroContext.userName`. Neither consumer uses server discovery, the benchmark runner, or the tool-calling public API.

## What's leaving in 0.6.0

- **KoboldCpp backend** — zero consumers on either audited app, no evidence of external interest, pure maintenance cost.
- **Server discovery subsystem** (~1,643 LOC) — zero consumers; built speculatively for a "find local LLM servers on the LAN" flow that never shipped.
- **Tool calling public API** (~800+ LOC) — zero consumers; the public surface is being removed while we audit the underlying `MessagePart` tool cases separately.
- **`MessagePart` tool cases** — pending schema audit; removed from the public API in 0.6.0 but kept in the persistence layer until the migration path is clear.

## What's staying (and why)

- **Streaming resilience** — production failure mode where transient network loss, provider 429s, or cold TLS handshakes kill a stream mid-token. We caught this because BCK runs in apps that ship to real users on real networks, not just demo flows.
- **Model handoff (latest-wins `LoadRequestToken`)** — production failure mode where the user taps model A, then model B before A finishes loading, and the stale A load corrupts the active state. We caught this because BCK runs in apps where users actually change their mind.
- **Memory pressure auto-unload** — production failure mode where iOS pages out the loaded model silently and the next generation crashes on a zero pointer. We caught this because BCK runs on real devices that also run Safari, Messages, and background tasks.
- **Mock backend (`MockInferenceBackend`)** — production failure mode where an app-level feature depends on BCK's streaming contract and has no way to test it without loading a real model. We caught this because BCK consumers write XCTests.
- **Certificate pinning (fail-closed on known cloud APIs)** — production failure mode where a mis-configured device trusts a compromised CA and silently leaks chat traffic. We caught this because BCK ships cloud backends that actually get used in production.

## Positioning

BaseChatKit is a drop-in chat framework with operational reliability guarantees, optimized for the ChatbotUI-iOS-shaped consumer: take `ChatView`, `SessionListView`, and `ModelManagementSheet` wholesale, inject an `InferenceService`, and compose app-level features (personas, story engines, lorebooks, custom tools) on top of the `ChatViewModel` API. The value is not "we support every backend" — it's "your chat UI keeps working when the network flickers, the user changes their mind mid-load, or iOS decides to reclaim your model's memory."

AnyLanguageModel optimizes for provider abstraction — one protocol, many providers, API familiarity with Apple's `FoundationModels`. BCK optimizes for production failure modes — drop-in UI, operational reliability, and the things that go wrong between the demo and the App Store review. These are adjacent but distinct positions. We don't compete on backend count; we compete on what happens when the demo ends.

## Deferred to Weeks 2-3

- **Compression repatriation** — the compression pipeline was originally Fireside's and will be moved back there once Fireside has a clean extraction path. It stays in BCK 0.6.0 to avoid breaking Fireside mid-release.
- **Macro engine deletion** — the full macro system is Fireside-only and will be deleted from BCK after Fireside takes ownership in its own codebase. ChatbotUI-iOS's `macroContext.userName` usage will migrate to a new `systemPromptContext` property before the engine leaves.
- **`BaseChatInference` target extraction** — splitting the inference-only surface out of `BaseChatCore` so that UI-less consumers (server-side, CLI tools, test harnesses) can depend on the engine without pulling SwiftUI types. Target for 0.7.0.

## Consumer impact

Fireside keeps building — `MacroExpander` and the compression pipeline both stay in 0.6.0. The macro engine deletion is explicitly coordinated with Fireside's extraction timeline; Fireside will not be broken by this release.

ChatbotUI-iOS keeps building — the `macroContext` property still exists in 0.6.0 alongside the new `systemPromptContext`. The migration is additive, not breaking. Drop-in UI, `ChatViewModel`, `ModelManagementSheet`, `APIConfigurationView`, and the HuggingFace downloader all remain unchanged.

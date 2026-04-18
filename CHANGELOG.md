# Changelog

## [0.9.2](https://github.com/roryford/BaseChatKit/compare/v0.9.1...v0.9.2) (2026-04-18)

**Gemma 4 support and prompt-template detection polish** — This release closes the last gaps in GGUF prompt-template detection. First-class Gemma 4 support lands via a dedicated `.gemma4` template with the correct `<|turn>` / `<|end_of_turn>` delimiters and an explicit `<|turn>system` turn ([#461](https://github.com/roryford/BaseChatKit/issues/461)); loading a Gemma 4 GGUF previously fell through to ChatML and emitted `<|im_start|>` tokens the model had never seen, producing garbage output. Detection of `gemma3` architectures also gets wired up — they now map to the existing `.gemma` template rather than falling through to ChatML. Relatedly, `PromptTemplateDetector.detect(from:)` now lets an unambiguous model architecture (phi, gemma, mistral) win over a conflicting Jinja chat template, because some phi3/phi4 GGUFs include `<|im_start|>` tokens in their template's compatibility branches and were being misidentified as ChatML (fixes [#464](https://github.com/roryford/BaseChatKit/issues/464)). Finally, the Device Info popover now surfaces the actual loaded model name above the backend engine row ([#466](https://github.com/roryford/BaseChatKit/issues/466)), so users can confirm which model is active at a glance.


## [0.9.1](https://github.com/roryford/BaseChatKit/compare/v0.9.0...v0.9.1) (2026-04-18)

**Tool-calling contracts, capability predicates, and a llama.cpp stability pass** — This release introduces the inference-layer building blocks for tool-calling: a generic `ToolCall` / `ToolResult` value type in `BaseChatInference` ([#433](https://github.com/roryford/BaseChatKit/issues/433)) gives host apps a typed, backend-agnostic channel for function-calling, and `ModelCapabilityTier` gains predicate-based query methods ([#447](https://github.com/roryford/BaseChatKit/issues/447)) so model-selection UIs can filter by device capability without manual tier comparisons. iPad's model management sheet now uses system popovers and a medium detent ([#345](https://github.com/roryford/BaseChatKit/issues/345), [#346](https://github.com/roryford/BaseChatKit/issues/346)), matching the platform's expected presentation style for content management. Four llama.cpp fixes close out the stability pass from v0.9.0: `stopGeneration()` is now thread-safe against the decode loop ([#418](https://github.com/roryford/BaseChatKit/issues/418)), context overflow in long multi-turn sessions is guarded at the prefill boundary ([#417](https://github.com/roryford/BaseChatKit/issues/417)), in-flight generation is aborted when the OS sends a memory pressure notification to prevent Metal buffer revocation from crashing the process ([#415](https://github.com/roryford/BaseChatKit/issues/415)), and the `.mappable` load strategy now correctly rejects models whose file size cannot plausibly fit available device memory rather than returning a silent `.allow` that only fails later inside llama.cpp ([#448](https://github.com/roryford/BaseChatKit/issues/448)).

## [0.9.0](https://github.com/roryford/BaseChatKit/compare/v0.8.4...v0.9.0) (2026-04-18)

**Single-authority load plan replaces four scattered context clamps.** Loading a model used to consult four independent code paths to answer "how much context can this device handle, and will the model even fit": `DeviceCapabilityService.canLoadModel`, `DeviceCapabilityService.safeContextSize`, `MemoryGate.check`, and `LlamaBackend.computeRamSafeCap`. Each had different inputs and different blind spots, so iPad OOM crashes kept resurfacing from new angles ([#398](https://github.com/roryford/BaseChatKit/issues/398), [#400](https://github.com/roryford/BaseChatKit/issues/400), [#411](https://github.com/roryford/BaseChatKit/issues/411)) — every fix landed in one layer but left the other three uninformed.

### What's new

`ModelLoadPlan` is a public `Sendable` value type computed once at the UI entry point and consumed unmodified by the service facade and every backend ([#419](https://github.com/roryford/BaseChatKit/issues/419), [#420](https://github.com/roryford/BaseChatKit/issues/420), [#421](https://github.com/roryford/BaseChatKit/issues/421), [#422](https://github.com/roryford/BaseChatKit/issues/422)). It carries:

- `effectiveContextSize` — the authoritative `n_ctx` to pass to the backend.
- `verdict` — one of `.allow` / `.warn` / `.deny`.
- `reasons: [Reason]` — structured causes (`.insufficientResident`, `.insufficientKVCache`, `.trainedContextExceeded`, `.absoluteCeilingReached`, `.memoryCeilingReached`) so UIs can surface specific guidance instead of a generic "too big" string.

`LoadDenyPolicy` replaces `MemoryGate`'s two-way deny behavior with three cases — `.throwError`, `.warnOnly`, and `.custom(closure)`. The closure receives the full plan (including `reasons`) for nuanced decisions. Configure via `InferenceService.denyPolicy`; defaults to `.throwError` on iOS and `.warnOnly` on macOS.

### What's gone

- `MemoryGate` and `InferenceService.memoryGate` removed entirely ([#424](https://github.com/roryford/BaseChatKit/pull/424)).
- `DeviceCapabilityService.canLoadModel` and `.safeContextSize` deleted ([#427](https://github.com/roryford/BaseChatKit/pull/427)). UI recommendation callers migrated to `ModelLoadPlan.canRunModel(sizeBytes:physicalMemoryBytes:)`.
- `LlamaBackend` retry-on-nil halving loop, `computeRamSafeCap`, and GGUF metadata-extraction helpers — ~150 lines deleted. The plan already carries the authoritative `n_ctx`, so the backend never recomputes.

### ⚠ Breaking change

**`InferenceBackend.loadModel(from:contextSize:)` is removed.** The protocol's sole load method now takes a `ModelLoadPlan`. Migration is mechanical:

```swift
// Before
try await backend.loadModel(from: url, contextSize: 4096)

// After (local GGUF / MLX)
let plan = ModelLoadPlan.compute(
    for: model,
    requestedContextSize: 4096,
    strategy: .mappable
)
try await backend.loadModel(from: url, plan: plan)

// After (cloud — context is server-enforced)
try await backend.loadModel(from: url, plan: .cloud())

// After (Apple Foundation Models — system owns allocation)
try await backend.loadModel(from: url, plan: .systemManaged(requestedContextSize: 4096))
```

`InferenceService.loadModel(from:contextSize:)` remains for one release as a deprecated convenience that builds a plan internally. It will be removed in the next release.

### CI coverage fix

`BaseChatInferenceTests` is now part of the CI matrix, after a macOS-only test hang in [#426](https://github.com/roryford/BaseChatKit/pull/426) (closes [#425](https://github.com/roryford/BaseChatKit/issues/425)) shipped through the previous matrix unnoticed.

## [0.8.4](https://github.com/roryford/BaseChatKit/compare/v0.8.3...v0.8.4) (2026-04-16)

**Architecture-aware llama KV cache math** — Llama.cpp context clamps were deriving their pre-allocation ceiling from a flat `8 KB`/token heuristic, which significantly under-counts real KV cost on modern GQA models — a 7B at fp16 sits closer to `128 KB`/token — so the ceiling for large models was optimistic in a way that still pressed against iPad's jetsam budget. Context sizing now derives the per-token KV estimate from each model's actual layer and attention geometry: `block_count × (k_width + v_width) × bytes_per_element`, read from GGUF metadata at preload time (`DeviceCapabilityService.safeContextSize`) and from the loaded `llama_model *` at runtime (`LlamaBackend.computeRamSafeCap`), with a new `ModelInfo.estimatedKVBytesPerToken` threading the preload estimate through chat model loading. Models whose metadata is missing the architectural fields fall back to the legacy 8 KB/token constant, so nothing regresses for models the parser can't introspect. ([#403](https://github.com/roryford/BaseChatKit/pull/403), closes [#401](https://github.com/roryford/BaseChatKit/issues/401)).

## [0.8.3](https://github.com/roryford/BaseChatKit/compare/v0.8.2...v0.8.3) (2026-04-16)

**iPad crash loading long-context GGUF models** — Loading a 32K–128K context GGUF on iPad was silently over-allocating KV cache and pushing the app past its per-app jetsam limit, triggering a SIGKILL inside `llama_init_from_model`. The root cause was that context sizing consulted `ProcessInfo.physicalMemory` — roughly 8 GB on a modern iPad — rather than the allocation budget returned by `os_proc_available_memory()`, which is typically closer to 3 GB on the same device. Context sizing is now jetsam-aware at both layers: `DeviceCapabilityService.safeContextSize()` derives the ceiling from available memory at the UI layer, and `LlamaBackend.computeRamSafeCap()` does the same for its own pre-allocation cap. A 3-attempt retry loop in `LlamaBackend` also halves `n_ctx` on clean init failures to cover near-threshold cases that return nil rather than being SIGKILLed outright. Proper per-architecture KV math ([#400](https://github.com/roryford/BaseChatKit/issues/400), [#401](https://github.com/roryford/BaseChatKit/issues/401)) is tracked as follow-up work ([#399](https://github.com/roryford/BaseChatKit/pull/399), closes [#398](https://github.com/roryford/BaseChatKit/issues/398)).

### Bug Fixes

* clamp GGUF context size based on available memory to prevent iPad crashes ([#398](https://github.com/roryford/BaseChatKit/issues/398)) ([#399](https://github.com/roryford/BaseChatKit/issues/399)) ([65c4537](https://github.com/roryford/BaseChatKit/commit/65c4537016e610151557012bbcd0bf380e546aef))

## [0.8.2](https://github.com/roryford/BaseChatKit/compare/v0.8.1...v0.8.2) (2026-04-15)

**LlamaBackend stop-and-reload reliability** — Two fixes to the llama.cpp backend's lifecycle around stopping a generation and disposing of the model. Hitting Stop mid-generation used to leave KV cache state from the interrupted run, so the next user message failed with "Failed to decode prompt" until the model was reloaded; the cache is now cleared at the start of each generation instead of conditionally at the end, so the Stop / new-message cycle works without touching the model ([#396](https://github.com/roryford/BaseChatKit/pull/396), closes [#390](https://github.com/roryford/BaseChatKit/issues/390)). Separately, `unloadModel()` schedules its tear-down on a detached task and returns before the llama.cpp context has actually been freed, which races Metal's `MTLDevice` deinit at process exit and can abort the process with a GGML assertion — turning green test runs red. A new `unloadAndWait() async` method schedules the same tear-down and awaits its completion before returning. The existing fire-and-forget `unloadModel()` is unchanged, so the new API is purely additive — tests and programmatic reload loops opt in only where determinism matters ([#395](https://github.com/roryford/BaseChatKit/pull/395), closes [#391](https://github.com/roryford/BaseChatKit/issues/391)).

## [0.8.1](https://github.com/roryford/BaseChatKit/compare/v0.8.0...v0.8.1) (2026-04-15)

**macOS Model Management sheet and UI test reliability** — Host apps running BaseChatKit on native macOS 26 were seeing the Model Management sheet open with blank content under every tab — Select, Download, and Storage — leaving model selection and downloads unreachable from the demo app. The underlying cause was a SwiftUI layout interaction: a `NavigationStack`/`VStack`/`List` tree inside a macOS sheet has no intrinsic size, so the tab content collapsed to zero height. An explicit minimum frame on the macOS sheet now gives the content stable room to lay out; iOS and iPad are unchanged because they size via `.presentationDetents`. This release also restores macOS demo UI test visibility (the app stayed backgrounded under XCUITest so tests could only see the menu bar) and fixes three flaky iPhone compact session-management tests where the shared sidebar-reveal helper was tapping at an off-screen centroid.

### Bug Fixes

* **ui:** render Model Management sheet tab content on macOS ([#378](https://github.com/roryford/BaseChatKit/issues/378)) ([#381](https://github.com/roryford/BaseChatKit/issues/381)) ([17aa3af](https://github.com/roryford/BaseChatKit/commit/17aa3afc29c70ed0f25d3ba09e4f6a1d201869ab))
* **ui:** guard macOS demo toolbar and regression-test sheet layout ([#384](https://github.com/roryford/BaseChatKit/issues/384)) ([eca970d](https://github.com/roryford/BaseChatKit/commit/eca970dda22e9de81a55ae974add1688e83c4ef5))
* **test:** restore macOS demo UI test visibility ([#377](https://github.com/roryford/BaseChatKit/issues/377)) ([#386](https://github.com/roryford/BaseChatKit/pull/386)) ([29e2230](https://github.com/roryford/BaseChatKit/commit/29e223028f1e52f1b87cf5bb406009dac1959fb7))
* **test:** reveal sidebar reliably on iPhone compact ([#388](https://github.com/roryford/BaseChatKit/pull/388)) ([a7b3a73](https://github.com/roryford/BaseChatKit/commit/a7b3a736c91b6a1eebf63957b10e4830c898007b))

## [0.8.0](https://github.com/roryford/BaseChatKit/compare/v0.7.8...v0.8.0) (2026-04-14)

**Security hardening pass** — twelve defensive changes across transport, credentials, at-rest data, streaming, and downloads, driven by a framework-wide security architect review. Integrators of BaseChatKit now inherit a measurably tighter default posture: the surface area that a malicious custom endpoint or a tampered download can reach is smaller, errors fail closed where they should, and the public API tells integrators what went wrong instead of silently degrading.

### ⚠ BREAKING CHANGES

**`KeychainService.store` and `.delete` now throw `KeychainError` instead of returning `Bool`.** Previously, a failed Keychain write (device locked, missing entitlement, out of space) silently returned `false`, and every caller we surveyed either discarded the result or only surfaced a generic "failed to save" banner — the user would configure an API key, see it "save", then get auth failures later with no indication why. The throwing API forces the failure to be acknowledged. `KeychainError` conforms to `LocalizedError` and maps common `OSStatus` codes (`errSecInteractionNotAllowed`, `errSecMissingEntitlement`, `errSecDuplicateItem`, etc.) to short user-facing sentences; an `osStatus` accessor is available for programmatic recovery. `APIEndpoint.setAPIKey` and `.deleteAPIKey` propagate the same error. Migration is mechanical: wrap the call in `try` inside a `do`/`catch`, or use `try?` where fire-and-forget cleanup is acceptable. ([#363](https://github.com/roryford/BaseChatKit/issues/363))

### Network defenses

**SSRF blocked at custom-endpoint validation.** User-configurable API endpoints could previously target internal networks — a malicious or mistaken configuration pointing at `http://192.168.1.1` or `http://169.254.169.254` (AWS instance metadata) would turn the device into a proxy into the user's LAN or cloud-metadata surface. `APIEndpoint.validate()` now rejects RFC1918 ranges (10/8, 172.16/12, 192.168/16), link-local (169.254/16, fe80::/10), IPv6 unique-local (fc00::/7), IPv4-mapped IPv6 loopback, multicast, reserved ranges, and non-`http(s)` schemes. Loopback remains allowed for local dev servers (Ollama). A trailing-dot FQDN bypass (`https://192.168.1.1.`) was found during review and closed. ([#360](https://github.com/roryford/BaseChatKit/issues/360))

**Typed `APIEndpointValidationReason` surfaces specific rejection reasons in the settings UI.** Before, the settings row rendered every invalid endpoint as a generic "Incomplete" label — users had no way to know they'd typed a private IP vs. misspelled the host. `APIEndpoint.validate() -> Result<Void, APIEndpointValidationReason>` now returns one of nine specific cases (`.privateHost`, `.linkLocalHost`, `.ipv6UniqueLocal`, `.ipv4MappedLoopback`, `.multicastReserved`, `.unsupportedScheme(String)`, `.insecureScheme`, `.malformedURL`, `.emptyURL`), each with a short actionable `errorDescription` surfaced as a subtitle on the endpoint row. `isValid: Bool` is preserved as a derived convenience for callers that only need a yes/no. ([#368](https://github.com/roryford/BaseChatKit/issues/368))

**SSE streams bounded against hostile-server memory and rate attacks.** `SSEStreamParser` had no caps on per-event size, total stream size, or event frequency, so a malicious or misconfigured upstream could exhaust client memory or saturate the consumer. New `SSEStreamLimits` defaults to 1 MB per event, 50 MB per stream, and 5,000 events/second — well above any realistic provider throughput — and throws `SSEStreamError.eventTooLarge` / `.streamTooLarge` / `.eventRateExceeded` through the existing `AsyncThrowingStream` error path. Tunable globally via `BaseChatConfiguration.shared.sseStreamLimits` or per-backend. Applied to both SSE (OpenAI, Claude, custom) and NDJSON (Ollama) paths. ([#361](https://github.com/roryford/BaseChatKit/issues/361))

**Upstream error bodies sanitized before reaching the UI.** `CloudBackendError.serverError.message` previously passed raw upstream JSON/HTML/text directly to the user-facing error description, which risked content injection if any renderer downstream treated it as attributed text, and leaked multi-kilobyte HTML proxy pages into error banners. `CloudErrorSanitizer` now strips control / zero-width / bidi-override scalars, rejects HTML-shaped payloads (falling back to `"Server error from <host>"`), redacts JWT- and URL-shaped tokens, collapses whitespace, and caps the message at 256 characters. Raw bodies remain visible in Console at `.debug` privacy for diagnostics. Wired into OpenAI, Claude, and Ollama backends. ([#364](https://github.com/roryford/BaseChatKit/issues/364))

### Credentials & at-rest data

**SwiftData store protected at rest on iOS/tvOS/watchOS.** `ModelContainerFactory` now applies `NSFileProtectionCompleteUntilFirstUserAuthentication` to the store file and its WAL sidecars, so chat history, saved endpoints, and sampler presets are sealed until the user unlocks the device once after reboot — protecting the corpus against offline attacks on a powered-off or freshly-booted device while preserving background-task compatibility. Configurable via `BaseChatConfiguration.fileProtectionClass` (set `.complete` for stricter, `nil` to opt out). macOS and Mac Catalyst are no-ops — FileVault handles at-rest protection there. In-memory stores are unaffected. ([#371](https://github.com/roryford/BaseChatKit/issues/371))

**Orphaned Keychain items reaped on boot.** Previously, an `APIEndpoint` row could be deleted through the SwiftData context (or its row-delete could succeed while the `KeychainService.delete` failed) and the Keychain item for that UUID would remain indefinitely — there was no mechanism to reclaim it. `BaseChatBootstrap.reapOrphanedKeychainItems(in:)` now sweeps the framework's Keychain service namespace on `SwiftDataPersistenceProvider.init`, deleting any item whose account UUID doesn't match a live `APIEndpoint`. The sweep is sub-millisecond for a typical namespace and logs the reap count at `.info`. Opt out via `BaseChatConfiguration.keychainReaperEnabled = false` for test harnesses that populate the namespace independently. ([#372](https://github.com/roryford/BaseChatKit/issues/372))

### Downloads & model input

**Download file-name validation + stale temp-file sweep.** Model filenames come from external manifests (HuggingFace or user-supplied) and previously relied only on a URL-standardization + prefix check to prevent traversal. `DownloadableModel.validate(fileName:)` now enforces explicit per-component rules (`.pathTraversal`, `.backslash`, `.emptyComponent`, `.tooManyComponents`, `.hidden`, `.tooLong`, `.controlCharacter`) as a layer on top. In-flight downloads were also leaking temp files to `/tmp` on crash; `BackgroundDownloadManager.cleanupStaleTempFiles()` now runs on session reconnect, scoped to files matching the manager's own `basechatkit-dl-<UUID>.download` pattern older than 24 hours, and logs the reclaimed count. ([#365](https://github.com/roryford/BaseChatKit/issues/365))

**Quantization-extraction regex bounded against ReDoS.** The `DownloadableModel.quantization` getter used an unbounded quantifier `(?:_[A-Z0-9]+)*` on externally-controlled filenames, which — combined with the trailing literal — allowed catastrophic backtracking on crafted input (a measured 250 ms on a 1,000-char pathological string, worst case unbounded). The quantifier is now `{0,5}` (real-world tags never exceed two suffix components) and input is clipped to 128 characters before the regex runs. ([#362](https://github.com/roryford/BaseChatKit/issues/362))

### Documentation & small hardening

**DocC `SecurityModel` article** documenting the full threat model: certificate pinning (`PinnedSessionDelegate`), SSRF allowlist, Keychain scope, at-rest protection expectations, SSE caps, upstream sanitization, download validation, and explicit out-of-scope (DNS rebinding, prompt injection, compromised-host threats). Linked from the README. ([#369](https://github.com/roryford/BaseChatKit/issues/369))

**`PinnedSessionDelegate` defense-in-depth.** The pin documentation had a stale comment that claimed pin sets were "intentionally left empty" when in fact `loadDefaultPins()` was shipping GTS WE1 intermediate + GTS Root R4 backup pins — a future maintainer reading the comment might have deleted the population code as dead. A regression-guard CI test now asserts both `api.openai.com` and `api.anthropic.com` ship with ≥2 pins each (primary + rotation backup). A separate small hardening fix adds a `guard scalars.count >= 2` to `CloudErrorSanitizer.containsHTMLTag` against a range-trap that was unreachable-today but one code reorder from real. ([#359](https://github.com/roryford/BaseChatKit/issues/359), [#370](https://github.com/roryford/BaseChatKit/issues/370))

**Build hotfix for interleaved merges.** `CustomEndpointValidationTests` was added by #360 while #363 was in review; both PRs' CI passed against their own bases but main briefly failed to compile once both landed because the test called the pre-#363 non-throwing `KeychainService.delete`. One-line `try?` fix. ([#374](https://github.com/roryford/BaseChatKit/issues/374))

## [0.7.8](https://github.com/roryford/BaseChatKit/compare/v0.7.7...v0.7.8) (2026-04-14)

### Features

**Adaptive iPad UX for hardware keyboards and split-view workflows** — iPad users with a hardware keyboard can now drive the app entirely from key commands: Cmd+Return sends a message, Cmd+N opens a new chat, Cmd+, opens Settings, Cmd+Shift+M opens Model Management, and Cmd+Shift+K clears the current chat. Settings, API configuration, and chat-export panels now present as popovers anchored to their trigger controls when the app runs at a regular horizontal size class, keeping the chat and sidebar visible instead of covering them with a full sheet (iPhone retains the sheet presentation). The model management sheet on iPad honours a `.medium` detent so users can browse or switch models without losing the split-view context behind it. Closes #344, #345, #346. ([#352](https://github.com/roryford/BaseChatKit/issues/352))

### Performance Improvements

**Coalesced SwiftUI redraws during model loading** — `ChatViewModel.applyModelLoadProgress` transitioned its `activityPhase` on every 50 ms progress tick, producing up to 20 observable invalidations per second and re-rendering every view bound to the phase (chat view, input bar, progress indicators). Progress-driven phase transitions are now throttled to ~4 Hz while the first emission and the terminal 1.0 emission are preserved, so the progress bar still feels immediate at the start and end without the churn in between. ([#357](https://github.com/roryford/BaseChatKit/issues/357))

### Bug Fixes

**Stale token counts after memory-pressure unload or message edit** — `ChatViewModel.tokenCountCache` and its cached `CachingTokenizer` survived `unloadModel()`, so a memory-pressure unload followed by loading a different model could return token counts keyed by a reused message UUID against the wrong tokenizer, distorting context-window estimates and triggering premature trimming. The caches are now invalidated together with the tokenizer identity marker on unload, `editMessage()` drops the affected entry right after the persistence update, and both the per-message cache and the cached tokenizer are marked `@ObservationIgnored` so writes no longer churn SwiftUI invalidations. ([#356](https://github.com/roryford/BaseChatKit/issues/356))

**Hardened SSE cloud-backend contract and concurrency** — `SSECloudBackend.init` now requires an `SSEPayloadHandler`, turning what was previously a runtime `fatalError` on a missing `extractToken(from:)` / `extractUsage(from:)` / `isStreamEnd(_:)` / `extractStreamError(from:)` override into a compile-time error for any external subclass (closes [#328](https://github.com/roryford/BaseChatKit/issues/328)). Separately, the `WeakBox<GenerationStream>` used by `generate()` was declared `@unchecked Sendable` with no lock guarding its mutable value, leaving a latent race for callers not pinned to `@MainActor`; `generate()` now uses `AsyncThrowingStream.makeStream()` — the same pattern already in `LlamaBackend`, `MLXBackend`, and `FoundationBackend` — so the stream is captured directly by value and the unsynchronised indirection is gone (closes [#327](https://github.com/roryford/BaseChatKit/issues/327)).

**Model download resume data moved out of UserDefaults** — `BackgroundDownloadManager` previously wrote each in-flight download's resume blob to `UserDefaults` under `resumeData.<id>`. A multi-GB model interrupted mid-transfer could leave 20–50 MB sitting in the plist that iOS loads synchronously at every app launch, measurably slowing cold start, and the pending-downloads dictionary could be corrupted by a crash between a `set` and the system's write-back. Resume data is now written atomically to one binary file per download under `Caches/<bundle>.downloads/`, pending metadata is a single JSON file replaced via temp-file rename, and a launch-time sweep deletes orphaned resume files from previously crashed sessions. A one-time migration moves any existing UserDefaults data to the new location the first time the updated app runs. ([#330](https://github.com/roryford/BaseChatKit/issues/330))

**Restored BaseChatInference imports after the re-export removal** — v0.7.7 removed the `@_exported import BaseChatInference` from `BaseChatCore`, exposing three call sites that had been relying on the transitive re-export: `AppearanceMode+ColorScheme.swift` in the UI layer (closes [#341](https://github.com/roryford/BaseChatKit/issues/341)) and the demo app's `DemoContentView` and `BaseChatDemoApp` (closes [#343](https://github.com/roryford/BaseChatKit/issues/343)). All three now `import BaseChatInference` directly, restoring the `swift build` green. PR #343 additionally fixes an iPad-only bug where `ChatContentView.onAppear` created a new session via `sessionManager.createSession()` but never set `activeSession`, leaving the detail pane in the split view stuck on "No session selected" until the user tapped a row; the first session is now auto-selected on launch.

**MLX-trait test compilation on Apple Silicon** — `MLXBackendTests`, `MLXBackendGenerationTests`, and `MLXModelE2ETests` referenced `GenerationConfig` and `GenerationStream` from `BaseChatInference` but never imported the module. Because the `MLX` trait is disabled in CI, the failures only showed up locally when running `swift test --traits MLX,Llama`. Imports added; no runtime behaviour change. ([#350](https://github.com/roryford/BaseChatKit/issues/350), [#358](https://github.com/roryford/BaseChatKit/issues/358))

## [0.7.7](https://github.com/roryford/BaseChatKit/compare/v0.7.6...v0.7.7) (2026-04-13)


### Bug Fixes

* **arch:** remove @_exported import BaseChatInference re-export from BaseChatCore ([#338](https://github.com/roryford/BaseChatKit/issues/338)) ([13f3d46](https://github.com/roryford/BaseChatKit/commit/13f3d460e73713991a588cd6198970039e2c75cf))
* **arch:** remove SwiftUI from inference layer and deprecate maxTokens ([#332](https://github.com/roryford/BaseChatKit/issues/332)) ([2ab67c3](https://github.com/roryford/BaseChatKit/commit/2ab67c3f5dd7197a7fc48f0fcb7f275a06e03043))
* **concurrency:** serialize BackgroundDownloadManager.cancelDownload taskContext read on MainActor ([20c6126](https://github.com/roryford/BaseChatKit/commit/20c61268500368d9c120dd24cb679d0cfe2c7a4c))
* **security:** sanitize model.fileName against path traversal in download placement ([#331](https://github.com/roryford/BaseChatKit/issues/331)) ([20c6126](https://github.com/roryford/BaseChatKit/commit/20c61268500368d9c120dd24cb679d0cfe2c7a4c))

## [0.7.6](https://github.com/roryford/BaseChatKit/compare/v0.7.5...v0.7.6) (2026-04-12)

**Model browser overhaul — smarter downloads, resilient transfers, and device-aware recommendations** — Six improvements to the model download and browsing experience, covering the full lifecycle from finding a model to getting it running.

Downloads now survive network interruptions. When a transfer fails part-way through — timeout, dropped connection, or the app moving to background — the download manager stores the incomplete file and resumes from the byte offset where it left off on retry, rather than starting over. A retry button appears inline on the failed row. Stale download state from previous sessions is also reconciled on launch: orphaned in-memory entries are removed and a diagnostic log is emitted for each cleanup, eliminating the phantom progress rows that could appear after a crash or force-quit. ([#322](https://github.com/roryford/BaseChatKit/pull/322), [#320](https://github.com/roryford/BaseChatKit/pull/320))

The moment a download completes, a "Use \<ModelName\> now?" alert appears automatically if the finished model is not already the active selection. Tapping "Use Now" maps the downloaded file to the corresponding `ModelInfo` and switches the session immediately, removing the extra tap to the Select tab. The prompt is suppressed if the model is already loaded, and only one prompt can be pending at a time so back-to-back downloads don't stack alerts. ([#319](https://github.com/roryford/BaseChatKit/pull/319))

Disk space errors are now surfaced before and during download. When a model's declared size exceeds the volume's available capacity for important usage, the download button is grayed out and disabled proactively, with an "Insufficient storage" caption below it. If a download is attempted anyway and fails with an `insufficientDiskSpace` error, the error message is formatted as a human-readable string (e.g. "Not enough storage — this model needs 4.1 GB but only 1.2 GB is available") rather than a raw system error. A blue "In Use" badge also replaces the green "Downloaded" badge for the currently loaded model, so the active model is visually distinct from others that happen to be on disk. ([#321](https://github.com/roryford/BaseChatKit/pull/321))

Search results are now sorted by device compatibility rather than raw download count. Groups whose variants fit comfortably in device RAM appear before oversized models regardless of HuggingFace popularity, with download count used only to break ties within the same compatibility tier. Inside each disclosure group, the best-fitting variant (the largest quantization that passes the memory check, or the smallest when nothing fits) is sorted to the top and labelled "Recommended" or "Smallest available" with a green capsule badge — matching the existing "Curated" badge style — so the right quant is obvious without cross-referencing the device's RAM manually. The search pool is also doubled from 20 to 40 repos, surfacing more quant options per query. ([#325](https://github.com/roryford/BaseChatKit/pull/325), [#323](https://github.com/roryford/BaseChatKit/pull/323))

## [0.7.5](https://github.com/roryford/BaseChatKit/compare/v0.7.4...v0.7.5) (2026-04-12)

**Streaming performance fix and background-cancellation handler** — Two improvements targeting the chat UI's behaviour during and after active generation.

When an assistant reply grew beyond ~1 KB, the UI was calling `AttributedString(markdown:)` on the full accumulated text on every token delivery. With a 500-token response that is 500 full re-parses of an ever-longer string — O(N²) total work — causing visible lag on Apple Silicon at 2 KB and above. A new `MarkdownAttributedStringCache` memoizes the rendered `AttributedString` per block: stable blocks (everything except the last, still-growing line) are returned from cache in O(1), reducing total rendering work to O(N). ([#301](https://github.com/roryford/BaseChatKit/pull/301), closes [#245](https://github.com/roryford/BaseChatKit/issues/245))

`ChatViewModel` now exposes `handleScenePhaseChange(to:)` so host apps can cleanly cancel active generation when the app moves to `.background`. Without this, a user pressing the home button mid-stream left a zombie generation task running until the backend eventually timed out or was killed by the OS. The method is a no-op on `.active` and `.inactive`, making it safe to call unconditionally from `onChange(of: scenePhase)`. ([#302](https://github.com/roryford/BaseChatKit/pull/302), closes [#241](https://github.com/roryford/BaseChatKit/issues/241))

## [0.7.4](https://github.com/roryford/BaseChatKit/compare/v0.7.3...v0.7.4) (2026-04-12)

**Test workflow hardening and persistence cleanup** — A cancelled assistant response could be saved twice, leaving orphaned rows that resurfaced after reload and forced the main user-journey E2E to tolerate known issues. This change makes chat-message persistence behave like an upsert at the view-model boundary, removes the known-issue wrappers from the end-to-end journey, tightens MLX integration fixture detection so malformed local snapshots are skipped instead of failing the suite, and stabilizes the Example app's UI test contract with explicit accessibility hooks plus a scripted `build-for-testing` / `test-without-building` loop. The result is a test matrix that is both more trustworthy and much faster to debug when failures do happen. ([#297](https://github.com/roryford/BaseChatKit/pull/297))

## [0.7.3](https://github.com/roryford/BaseChatKit/compare/v0.7.2...v0.7.3) (2026-04-11)

**Load progress, an InferenceService audit, and internal hardening** — Three improvements from a focused audit of `InferenceService` and its supporting infrastructure.

`LlamaBackend` now adopts `LoadProgressReporting` using the llama.cpp C API's `progress_callback` hook, publishing real fractional progress through `InferenceService.modelLoadProgress` as weights load. `MLXBackend` adopts the same protocol with synthetic `0.0`/`1.0` bookends — the `mlx-swift-lm` local-directory load path exposes no granular progress hook, so the bookend approach replaces the previous flat spinner with a signal that reflects actual load state. The `LoadProgressReporting` infrastructure in `InferenceService` was complete but adopted by no production backend; both backends now wire into it. ([#290](https://github.com/roryford/BaseChatKit/pull/290))

The `unloadModel()` mid-stream safety invariant is now locked in by test. An audit of `InferenceService` confirmed that the existing guards — `stopGeneration()` nils `activeRequest` synchronously before the cancelled Task's defer fires, the auto-drain token guard prevents re-entry on a cancelled slot, and `enqueue()` rejects calls when `backend == nil` — are sufficient to prevent state corruption when a model is unloaded while generation is active. Two tests lock this in: one that unloads before any tokens flow and one that unloads after tokens start streaming, both verifying that `isModelLoaded`, `isGenerating`, and `hasQueuedRequests` are clean afterward and that a subsequent `enqueue()` correctly throws. ([#288](https://github.com/roryford/BaseChatKit/pull/288))

Two smaller improvements round out the release: `NSRegularExpression` for system prompt context substitution is now compiled once as a file-private top-level constant rather than on every generation call ([#287](https://github.com/roryford/BaseChatKit/pull/287)), and `BackgroundDownloadManager` is split into three focused files — the GGUF/MLX format validation logic extracted into a standalone `DownloadFileValidator` struct and the `URLSessionDownloadDelegate` conformance moved to its own extension file, reducing the main file from 821 to ~600 lines ([#289](https://github.com/roryford/BaseChatKit/pull/289)).

## [0.7.2](https://github.com/roryford/BaseChatKit/compare/v0.7.1...v0.7.2) (2026-04-11)

**Generation queue hardening — auto-drain and title generation race eliminated** — Two fixes targeting the InferenceService generation queue, both discovered during an audit of the service's blast radius against consumers like Fireside.

The first fix removes the manual `generationDidFinish()` contract that previously required every `enqueue()` caller to call back into the service after consuming its stream — failure to do so stalled the queue permanently with no error surfaced anywhere. The queue now auto-drains when the stream terminates: the `drainQueue()` task's defer block clears the active request and kicks the next item when the stream finishes, errors, or is cancelled. A token guard (`activeRequest?.token == next.token`) prevents re-entry when `cancel()` or `stopGeneration()` have already cleared the slot. `generationDidFinish()` is retained as a deprecated no-op so existing call sites compile unchanged. ([67ec85c](https://github.com/roryford/BaseChatKit/commit/67ec85c00f89e069b8c280a0cb5228e905a1b224))

The second fix routes title generation through `enqueue(priority: .background, sessionID: nil)` instead of the non-queued `generate()` path. Previously, `SessionManagerViewModel.generateTitle()` called `generate()` directly, which bypassed the priority queue, thermal gating, and session scoping. On MLXBackend, this meant a title generation and an active chat generation could race for the backend's main-thread lock, risking main-thread starvation mid-stream. Title requests now queue as background priority behind any active user-initiated generation, are subject to thermal gating, and drain automatically when complete. ([7afd4d6](https://github.com/roryford/BaseChatKit/commit/7afd4d6d40f415aa36b1d641e311e261ba2e6243))

## [0.7.1](https://github.com/roryford/BaseChatKit/compare/v0.7.0...v0.7.1) (2026-04-11)

**Accessibility contract tests and VoiceOver polish for chat UI** — The chat view's accessibility surface had no automated coverage because the existing snapshot harness captured view hierarchies via `Swift.dump()`, which strips accessibility labels. This release adds a ViewInspector-driven `ChatA11yContractTests` suite and tightens the labels VoiceOver users actually hear: message bubbles now announce `"User said: …"` / `"Assistant said: …"` instead of the raw enum rawValue, the context indicator reads `"Context used: 1234 of 4096 tokens"` at `"50 percent"`, and the error banner is exposed as an accessibility header with an `"Error: …"` prefix so screen-reader users can orient to it as a landmark. Existing visual snapshots and behaviour are unchanged. ([#258](https://github.com/roryford/BaseChatKit/pull/258))

## [0.7.0](https://github.com/roryford/BaseChatKit/compare/v0.6.0...v0.7.0) (2026-04-10)

**Structural slimming — inference target extracted, compression and macros retired** — 0.7.0 is the structural follow-up to 0.6.0's scope cut. Where 0.6.0 deleted subsystems with zero audited consumers and repositioned BCK around its operational-reliability guarantees, 0.7.0 finishes the job: the inference-orchestration surface is split into its own SPM target so UI-less consumers can drop SwiftData from their build graph, two subsystems that 0.6.0 deferred (the compression pipeline and the full macro engine) are now fully removed after their single remaining consumer vendored local copies, and the tool-calling removal trail from [#269](https://github.com/roryford/BaseChatKit/pull/269) is closed out by deleting the persisted `MessagePart` tool cases after a schema audit confirmed they were never populated in any shipped store. The canonical rationale for the slimming initiative remains in [docs/SCOPE_DECISION.md](https://github.com/roryford/BaseChatKit/blob/main/docs/SCOPE_DECISION.md); 0.7.0 is the structural correction that that document called for.

### New target: BaseChatInference

BCK's inference surface — `InferenceService`, backend protocols, generation events, context window management, prompt assembly, repetition detection, tokenizers, the capability API, and the framework configuration — now lives in a standalone `BaseChatInference` SPM target ([#271](https://github.com/roryford/BaseChatKit/pull/271)). Previously every consumer that imported `BaseChatCore` for inference orchestration also pulled in SwiftData, the `@Model` types, the persistence provider, and the chat export service, even if those consumers never touched persistence at all. Server-side runners, CLI tools, test harnesses, and host-app feature modules that compose their own persistence can now depend on `BaseChatInference` alone and leave `BaseChatCore` out of their build graph entirely. `BaseChatBackends` also sheds its dependency on `BaseChatCore` and now depends directly on `BaseChatInference`, so backend implementations are structurally incapable of reaching for SwiftData types. Existing apps that import `BaseChatCore` are unaffected: `BaseChatCore` contains `@_exported import BaseChatInference`, so every inference symbol is still reachable through the old import path with no source changes.

### Subsystems retired

Two complete subsystems leave BCK in this release after consumer audits confirmed both had only a single internal consumer that had since vendored its own local copy. The **compression pipeline** ([#276](https://github.com/roryford/BaseChatKit/pull/276)) removes roughly 3,240 lines across `AnchoredCompressor`, `ExtractiveCompressor`, `CompressionOrchestrator`, `ContextCompressor`, `CompressionMode`, `CompressibleMessage`, `CompressionStats`, the `CompressionIndicatorView` UI, and 13 compression test files spanning the Inference, UI, and E2E suites. The `compressionMode` field on `ChatSessionRecord` and the `compressionModeRaw` storage on the `@Model ChatSession` are also gone. History trimming now runs unconditionally through `ContextWindowManager.trimMessages`, which continues to honor pinned messages and the configured context window. The **macro engine** ([#275](https://github.com/roryford/BaseChatKit/pull/275)) removes `MacroExpander`, `MacroProvider`, `MacroContext`, `ChatViewModel.macroContext`, `ChatViewModel.macroExpansionEnabled`, and the `buildMacroContext()` helper. The simpler `systemPromptContext: [String: String]` API that shipped in 0.6.0 as [#265](https://github.com/roryford/BaseChatKit/pull/265) now serves as the sole expansion path — apps set `viewModel.systemPromptContext["userName"] = name` and the substitution runs as a non-recursive pass over the dict before the prompt is assembled.

The third refactor in this release closes the tool-calling removal trail from 0.6.0. [#270](https://github.com/roryford/BaseChatKit/pull/270) deletes the `MessagePart.toolCall` and `.toolResult` enum cases after a schema audit confirmed that no shipped SwiftData schema version ever populated them — the cases existed only in SwiftUI previews, Codable round-trip fixtures, and an unmerged feature branch. `ChatMessage.decode` already falls back to a text bubble on unknown discriminators, so any hypothetical legacy row containing a tool-case part degrades gracefully on load rather than crashing, and a regression test locks that fallback behavior in place.

### Breaking changes

Apps that directly reference any of the removed symbols will not compile against 0.7.0. The migration path for each is noted inline.

- `MacroExpander`, `MacroProvider`, and `MacroContext` public types — deleted. Apps that relied on custom `MacroProvider` registrations should vendor their own expansion layer.
- `ChatViewModel.macroContext` and `ChatViewModel.macroExpansionEnabled` — deleted. Migrate `viewModel.macroContext.userName = name` to `viewModel.systemPromptContext["userName"] = name`. The dictionary key is caller-controlled; the old API hardcoded fields such as `userName` and `charName`. If your template tokens were `{{user}}` or `{{char}}`, use `systemPromptContext["user"]` and `systemPromptContext["char"]`.
- `buildMacroContext()` helper on `ChatViewModel` — deleted alongside the rest of the macro surface.
- Built-in macro tokens such as `{{date}}`, `{{time}}`, `{{weekday}}`, `{{isodate}}`, `{{random::a::b}}`, and `{{lastMessage}}` no longer auto-expand. Compute the value at the call site and inject it via `systemPromptContext["date"] = ...` before calling `sendMessage`.
- `CompressionMode`, `CompressionOrchestrator`, `AnchoredCompressor`, `ExtractiveCompressor`, `CompressibleMessage`, `CompressionStats`, `CompressionResult`, `ContextCompressor`, and `CompressionIndicatorView` — deleted. Apps that need history summarization should pin to the 0.6.x line or vendor a local copy of the strategies.
- `ChatViewModel.compressionMode` and `ChatViewModel.lastCompressionStats` — deleted.
- `ChatSession.compressionMode` / `compressionModeRaw` and `ChatSessionRecord.compressionMode` — deleted.
- `ContextIndicatorView.init(usedTokens:maxTokens:lastCompressionStats:)` — the third parameter is removed; call the two-parameter form.
- `MessagePart.toolCall(id:name:arguments:)` and `MessagePart.toolResult(id:content:)` enum cases — deleted. Code that pattern-matches on `MessagePart` with an exhaustive switch must drop the corresponding arms.
- `BaseChatBackends` now depends on `BaseChatInference`, not `BaseChatCore`. Apps whose backend-adjacent code imported `BaseChatCore` transitively through `BaseChatBackends` may need to add an explicit `import BaseChatInference` (or keep `import BaseChatCore`, which re-exports the same symbols).
- `InferenceService.loadCloudBackend(from:)` and `SettingsService.effectiveTemperature`/`effectiveTopP`/`effectiveRepeatPenalty(session:)` now accept the new `APIEndpointRecord` / `ChatSessionRecord?` value types introduced in `BaseChatInference`. A `BaseChatCore` extension preserves the old `@Model APIEndpoint` and `@Model ChatSession` call sites via adapter overloads, so persistence-backed call sites compile unchanged.

### Compatibility and migration

Persisted data survives the upgrade. `ChatSession.compressionModeRaw` was an optional `String?` column with a nil default, so SwiftData's automatic schema migration silently drops it the next time the store is opened — there is no migration error and the inference pipeline no longer reads the value. Any `MessagePart` JSON rows that somehow contained a tool-case discriminator would decode to a plain text bubble through `ChatMessage.decode`'s existing fallback, though the audit in [#270](https://github.com/roryford/BaseChatKit/pull/270) confirmed no shipped schema version ever wrote such rows. Consumers that previously set `viewModel.macroContext.userName = name` should switch to `viewModel.systemPromptContext["userName"] = name` — the dict-based API is strictly simpler and has been available since 0.6.0 as the forward-compatible replacement. Consumers that need history compression should either pin to 0.6.x or vendor a local copy of the strategies; context trimming via `ContextWindowManager` remains in BCK unchanged.

### Size reduction

After 0.6.0's deletions and the structural changes in this release, BCK's source tree is roughly 35% smaller than the pre-slimming baseline.

## [0.6.0](https://github.com/roryford/BaseChatKit/compare/v0.5.4...v0.6.0) (2026-04-10)

**Slimming pass — BCK refocuses on production reliability** — A consumer audit of BaseChatKit's two known consumers (a private internal app and the public [ChatbotUI-iOS](https://github.com/roryford/ChatbotUI-iOS) demo) found that less than half of the codebase had real demand. Several large subsystems had zero consumers on either side, and several more were carrying public API surface that would have frozen into 1.0 commitments without any validating users. 0.6.0 is the correction: delete what nobody uses, add the small amount of new API that the audited apps actually need, and reposition BCK around the operational-reliability guarantees that make it valuable to the consumers that ship it. The full rationale, the audit table, and the "what's leaving / what's staying" decisions are recorded in [docs/SCOPE_DECISION.md](https://github.com/roryford/BaseChatKit/blob/main/docs/SCOPE_DECISION.md).

### What was removed

Three subsystems leave the public API this release. The **KoboldCpp backend** ([#266](https://github.com/roryford/BaseChatKit/pull/266)) is gone — zero references in either audited consumer, no evidence of external interest, and KoboldCpp's HTTP API is largely OpenAI-compatible, so apps that still need it can point the custom OpenAI-compatible endpoint path at a KoboldCpp server instead. The **server discovery subsystem** ([#268](https://github.com/roryford/BaseChatKit/pull/268)) — roughly 1,825 lines of Bonjour plus network port-scanning code built speculatively for a "find local LLM servers on the LAN" flow — also had zero consumers on either side; apps that need local discovery can implement their own scanner or use the existing custom-endpoint UI to enter URLs manually. The **tool calling public API surface** ([#269](https://github.com/roryford/BaseChatKit/pull/269)) — `ToolProvider`, `ToolCallingBackend`, and all tool-specific types — was experimental scaffolding that would have become a load-bearing 1.0 contract without any real users exercising it. Removing it now lets a future release ship a stable cross-backend tool-calling design without the burden of maintaining the current shape in parallel.

Note that the `BackendCapabilities.supportsToolCalling: Bool` property stays in place, since removing it is a separable breaking change and keeping the capability-advertising surface stable is useful for apps that want to light up tool UI when a stable contract ships. `MessagePart.toolCall` and `.toolResult` enum cases also remain in this release because they are persisted in the SwiftData schema and need a dedicated migration path.

### New API

A new `ChatViewModel.systemPromptContext: [String: String]` property ([#265](https://github.com/roryford/BaseChatKit/pull/265)) provides a simple key/value substitution pass for the system prompt — apps that want to inject a username, a persona name, or any other small value into their prompts no longer need to wire up a full `MacroProvider` registry. The substitution runs at the existing macro expansion site in `ChatViewModel+Generation`, immediately after `MacroExpander.expand()`, so applications that rely on the richer `macroContext` pipeline continue to work unchanged and `MacroExpander` wins on key collisions. Both APIs coexist in 0.6.0; the full macro system is deferred to a later release pending coordination with its one consumer.

### Positioning update

BCK's README and the new [docs/SCOPE_DECISION.md](https://github.com/roryford/BaseChatKit/blob/main/docs/SCOPE_DECISION.md) ([#264](https://github.com/roryford/BaseChatKit/pull/264)) now lead with the framework's actual value proposition: a drop-in chat framework with operational reliability guarantees — streaming resilience across transient network loss and provider errors, latest-wins model handoff so rapid model switches cannot corrupt active state, memory pressure auto-unload so iOS cannot silently page out a loaded model, a mock backend so apps can unit-test their streaming contracts without loading a real model, and certificate pinning on known cloud APIs so misconfigured devices cannot silently leak chat traffic. These are the production failure modes BCK has caught because it runs in apps that ship to real users on real networks. The docs also clarify that BCK and HuggingFace's [AnyLanguageModel](https://github.com/huggingface/swift-transformers) occupy adjacent rather than competing niches: AnyLanguageModel optimizes for provider abstraction, BCK optimizes for what happens when the demo ends.

### Breaking changes

Apps that directly reference any of the removed symbols will not compile against 0.6.0. The migration path for each is noted inline.

- `APIProvider.koboldCpp` enum case — use `APIProvider.custom` with a KoboldCpp endpoint URL.
- `ServerType.koboldCpp` enum case — removed along with the enum's owning subsystem.
- `KoboldCppBackend` class — instantiate a custom OpenAI-compatible backend pointed at your KoboldCpp server.
- `ServerDiscoveryService` protocol, `DiscoveredServer`, `ServerType`, `NetworkDiscoveryService`, `BonjourDiscoveryService`, `ServerDiscoveryView`, `ServerDiscoveryViewModel`, `MockServerDiscoveryService` — apps that need local server discovery should implement their own scanner or accept URLs via the existing custom-endpoint configuration UI.
- `BaseChatConfiguration.FeatureFlags.showServerDiscovery` — the flag and its associated UI are gone; remove the assignment.
- `ToolCallingBackend` protocol, `ToolProvider`, `ToolCall`, `ToolDefinition`, `ToolResult`, `ToolSchema`, `ToolCallingError`, `ToolCallObserver`, `MockToolProvider` — apps that depend on tool calling should pin to 0.5.x until a stable cross-backend contract is designed in a later release.
- `GenerationEvent.toolCall` case — removed alongside the tool calling API surface. Event handlers that exhaustively switched on the enum lose a case but gain nothing to handle.
- `StreamAction.noOp` case — unused in the remaining streaming paths.
- `ChatViewModel.toolProvider` and `ChatViewModel.toolCallObserver` public accessors — removed with the rest of the tool surface.

### Compatibility

Persisted data survives the upgrade. Any saved KoboldCpp endpoints in an app's SwiftData store silently convert to `APIProvider.custom` on load; there is no data loss, but users will see the provider label change in the settings UI. The `MessagePart.toolCall` and `.toolResult` enum cases are deliberately retained in `BaseChatSchemaV3` this release because removing them requires a SwiftData migration; a future release will address that with a proper schema version bump.

### Additional improvements shipped in 0.6.0

Several non-slimming improvements also land in this release: an explicit state machine for `ChatViewModel.activityPhase` that eliminates ambiguous intermediate states ([#261](https://github.com/roryford/BaseChatKit/pull/261)), a visible compression stats indicator so users can see when prompt compression is active and by how much ([#255](https://github.com/roryford/BaseChatKit/pull/255)), a new `OperationalError` type that surfaces previously silent `try?`/`catch` failures through a dedicated error channel ([#262](https://github.com/roryford/BaseChatKit/pull/262)), and several focused UX fixes in `ChatView`, `ChatInputBar`, `SessionListView`, and `ModelManagementSheet` ([#250](https://github.com/roryford/BaseChatKit/pull/250), [#251](https://github.com/roryford/BaseChatKit/pull/251), [#252](https://github.com/roryford/BaseChatKit/pull/252), [#253](https://github.com/roryford/BaseChatKit/pull/253)).

## [0.5.4](https://github.com/roryford/BaseChatKit/compare/v0.5.3...v0.5.4) (2026-04-10)

**Security and stability hardening** — Three fixes targeting resource leaks, memory safety, and conditional compilation correctness.

**Ephemeral API key zeroing** — `SSECloudBackend` previously stored in-memory API keys as plain Swift `String` values, which make no guarantee about zeroing backing memory on deallocation. Keys could linger in freed heap pages and be recoverable from a memory dump on a compromised device. Keys are now stored in a `SecureBytes` wrapper that uses `memset_s` (compiler-elision-safe) to zero its buffer whenever the key is replaced, `unloadModel()` is called, or the backend is deallocated. Keychain-backed storage remains the recommended path for production; the property documentation now makes the residual risk of transient `String` copies in HTTP headers explicit ([#236](https://github.com/roryford/BaseChatKit/pull/236)).

**llama.cpp RAII handle wrapping** — `LlamaBackend` held raw C pointers (`llama_model *`, `llama_context *`) as unmanaged stored properties. If the model-load path threw after the model was allocated but before the context was created, the model pointer leaked with no cleanup path. Both pointers are now wrapped in private RAII handle types that call the appropriate `llama_free_*` function on `deinit`, making cleanup unconditional regardless of how the load path exits ([#235](https://github.com/roryford/BaseChatKit/pull/235)).

**MLX and Llama trait propagation** — The `MLX` and `Llama` Swift package traits were not being forwarded as compilation conditions to dependent targets, causing `#if MLX` and `#if Llama` guards inside `BaseChatBackends` to evaluate incorrectly. Conditional compilation blocks that should have been excluded from CI builds were being compiled, and blocks that should have been included in hardware builds were being skipped. The trait definitions in `Package.swift` now correctly propagate to all targets that depend on the backend ([#233](https://github.com/roryford/BaseChatKit/pull/233)).

## [0.5.3](https://github.com/roryford/BaseChatKit/compare/v0.5.2...v0.5.3) (2026-04-10)

**Model-load progress and MLX cache tuning** — Two improvements to the local inference path.

`InferenceService` now publishes `modelLoadProgress: Double?` so UI code can render real fractional load progress instead of an indeterminate spinner. Backends with granular progress hooks can opt into the new `LoadProgressReporting` protocol to publish fractional updates as weights load; backends without it continue to work unchanged, showing `0.0` for the load duration. `ChatViewModel.activityPhase` automatically mirrors the value through `.modelLoading(progress:)`, so any view that already observes activity phase picks up the new behaviour without changes. llama.cpp and MLX backend adoption will follow in subsequent releases ([#230](https://github.com/roryford/BaseChatKit/pull/230)).

MLX's GPU buffer cache size is now consumer-tunable via `MLXBackend(cachePolicy:)`. The previous hardcoded 20 MB was inherited from the `mlx-swift-examples` LLMEval sample — a minimum-footprint demo value that was too small for sustained inference on Apple Silicon, forcing MLX to constantly evict and reallocate Metal buffers between forward passes. The new `.auto` default scales by physical memory: 64 MB on ~6 GB iOS devices through 1 GB on 36+ GB Macs. Consumer apps that have benchmarked their workloads can pass `.generous`, `.minimal`, or `.explicit(bytes:)` to the initialiser. All existing `MLXBackend()` call sites pick up the new default without any code changes ([#232](https://github.com/roryford/BaseChatKit/pull/232)).

## [0.5.2](https://github.com/roryford/BaseChatKit/compare/v0.5.1...v0.5.2) (2026-04-09)

**Demo app hardening** — A code review of the demo app uncovered a build failure, broken recovery UX, layout issues on large displays, and an overly strict memory gate that rejected models that would have loaded fine.

LlamaBackend failed to compile under Xcode 26 / Swift 6.3 due to three strict concurrency violations: a non-isolated global static, `NSLock.lock()` calls inside `Task.detached` async contexts, and a circular reference in `unloadModel()`. These are fixed with `nonisolated(unsafe)`, a synchronous lock wrapper, and direct lock/unlock calls respectively ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

The error banner's Retry and Check API Key buttons previously just dismissed the error without performing any recovery. Retry now calls `regenerateLastResponse()`, and Check API Key opens the API configuration sheet. The model loading indicator also gains a Cancel button so users aren't forced to wait or force-quit during long loads ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

Message bubbles are now capped at 700pt width so text stays readable on ultrawide and 5K displays, where the previous spacer-only constraint let bubbles stretch across the full window. The macOS demo window defaults to 900×700 with a 600×400 minimum to prevent unusable resize states ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

The endpoint editor's Save button now requires a non-empty model name and trims whitespace. Endpoint deletion logs errors instead of silently swallowing them. The sidebar model section shows a loading spinner during model load and an error indicator on failure, eliminating the dead-end state new users hit when no model is available ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

The `MemoryGate` resident strategy was multiplying the model file size by 1.20× to account for KV cache, but KV cache is allocated during inference, not at load time. This caused the gate to reject ~4.6 GB models on 16 GB devices when the process had already used 1–2 GB. The check now uses the raw file size ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

## [0.5.1](https://github.com/roryford/BaseChatKit/compare/v0.5.0...v0.5.1) (2026-04-09)

**Stable model identity** — Model selection no longer silently resets after app restart, session switch, or model list refresh. `ModelInfo(ggufURL:)` and `ModelInfo(mlxDirectory:)` generated a random UUID on every call, so each `refreshModels()` rescan assigned new IDs to the same files on disk. Sessions persist `selectedModelID`, but the saved UUID never matched after a rescan — leaving users with "No model selected" despite having previously chosen one. IDs are now derived deterministically from the file path using UUID v5 (SHA-1, RFC 4122), so the same model file always produces the same identifier ([#224](https://github.com/roryford/BaseChatKit/pull/224)).

This release also adds 61 macOS control-visibility snapshot tests across ChatView, ModelManagementSheet, GenerationSettingsView, SessionListView, ChatExportSheet, and APIConfigurationView, and enables the Llama (GGUF) backend trait by default alongside MLX ([#223](https://github.com/roryford/BaseChatKit/pull/223), [#225](https://github.com/roryford/BaseChatKit/pull/225)).

## [0.5.0](https://github.com/roryford/BaseChatKit/compare/v0.4.1...v0.5.0) (2026-04-09)

**Breaking API improvements bundled with mlx-swift-lm migration** — An upstream change in mlx-swift-lm forced a breaking update to MLXBackend's model loading API. We used this as the trigger to ship six additional breaking improvements that fix real bugs, improve correctness, and reduce future maintenance cost.

mlx-swift-lm 2.31.3 declared `Hub` as a transitive dependency that Swift 6.3 / Xcode 26 now rejects. Commit `d1b14783` on mlx-swift-lm's main branch moves hub code to a new `MLXHuggingFace` target, but also changes the `loadModelContainer` signature. `MLXBackend` now uses the new `loadModelContainer(from:using:)` API with `TokenizerLoader` ([#221](https://github.com/roryford/BaseChatKit/pull/221)).

`SettingsService.globalTemperature`, `globalTopP`, and `globalRepeatPenalty` were `Float` properties that used `UserDefaults.float(forKey:)`, which returns 0 for missing keys — making it impossible to distinguish "user set temperature to 0.0" from "never configured." These are now `Float?`, with resolution helpers falling back to hardcoded defaults (0.7, 0.9, 1.1) when both session override and global are nil.

`ChatSessionRecord` stored compression mode, prompt template, and pinned message IDs as raw strings (`compressionModeRaw`, `promptTemplateRawValue`, `pinnedMessageIDsRaw`), accepting invalid values silently. These are now typed stored properties (`compressionMode: CompressionMode`, `promptTemplate: PromptTemplate?`, `pinnedMessageIDs: Set<UUID>`), with raw-to-typed conversion handled by `SwiftDataPersistenceProvider` at the persistence boundary.

`APIEndpoint.apiKey` was a computed property that performed Keychain I/O directly from a SwiftData `@Model`, breaking testability. The property is removed; callers now use `KeychainService.retrieve(account: endpoint.keychainAccount)` directly. `isValid` is now a pure structural check (URL scheme, host, HTTPS for non-localhost) and no longer queries the Keychain. Check `APIProvider.requiresAPIKey` separately for credential readiness.

`SessionManagerViewModel.deleteSession` and `renameSession` silently swallowed persistence errors. Both now throw, with a `guard let persistence` check matching `createSession`'s existing pattern. `SessionListView` surfaces errors via alert. The deprecated `configure(modelContext:)` convenience on both `ChatViewModel` and `SessionManagerViewModel` is removed — use `configure(persistence:)` with an explicit provider.

`BackendCapabilities` had two initializers: a 4-param convenience and a 12-param full init. The convenience is removed and all parameters on the single remaining init now have sensible defaults, so adding new capabilities in the future never forces changes to every backend or test mock.

### Migration guide

| Change | Migration |
|--------|-----------|
| `MLXBackend` loading API | Update custom MLX loading code to new `loadModelContainer(from:using:)` |
| `BackendCapabilities` 4-param init removed | Labeled-arg call sites compile unchanged; positional callers switch to labels |
| `ChatSessionRecord` raw string fields removed | Use `.compressionMode`, `.promptTemplate`, `.pinnedMessageIDs` |
| `APIEndpoint.apiKey` removed | Use `KeychainService.retrieve(account: endpoint.keychainAccount)` |
| `APIEndpoint.isValid` no longer checks API key | Check `APIProvider.requiresAPIKey` separately |
| `configure(modelContext:)` removed | Use `configure(persistence: SwiftDataPersistenceProvider(modelContext:))` |
| `deleteSession` / `renameSession` now throw | Wrap in `do/catch` |
| `globalTemperature` / `globalTopP` / `globalRepeatPenalty` are `Float?` | Handle optional; use `?? 0.7` etc. for display |

## [0.4.1](https://github.com/roryford/BaseChatKit/compare/v0.4.0...v0.4.1) (2026-04-08)

**Concurrency hardening and test coverage expansion** — A comprehensive codebase review uncovered three concurrency hazards that could cause data races under load, plus gaps in input validation and test coverage. This patch fixes all three races, adds URL validation to the endpoint editor, documents protocol threading contracts, and ships 117 new tests.

`MLXBackend` stored mutable state (`isModelLoaded`, `isGenerating`, `modelContainer`) without synchronization across `Task` boundaries — concurrent model loads and generation stops could race. The backend now uses `NSLock` matching the existing `LlamaBackend` pattern, with `unloadModel()` consolidated into a single critical section to prevent observable inconsistent state ([#218](https://github.com/roryford/BaseChatKit/pull/218)).

`ChatViewModel` looked up message indices via `firstIndex(where:)` and then mutated at that index, but any `await` between lookup and mutation could leave the index stale. A new `mutateMessage(id:_:)` helper combines lookup and mutation atomically, replacing four bare subscript sites. `InferenceService` also had a continuation leak: `AsyncThrowingStream.Continuation` objects could survive cancellation if an exception was thrown before cleanup ran — a `defer` block now guarantees cleanup in all paths.

The API endpoint editor previously accepted arbitrary URL strings with no validation. It now rejects malformed URLs, non-HTTP schemes, and plain HTTP to non-localhost addresses. The inline stream consumption logic in `ChatViewModel+Generation` has been replaced with `GenerationStreamConsumer.handle()`, removing duplicate code and the associated TODO. `CachingTokenizer` is now reused across generation cycles instead of being recreated each time, with identity-based invalidation that correctly handles both reference-type and value-type tokenizers.

Three protocols — `InferenceBackend`, `ToolProvider`, and `ServerDiscoveryService` — now document their threading contracts for downstream conformers. New tests cover `NetworkDiscoveryService` JSON parsing for all four server types (26 tests), UI view logic for `ChatInputBar`, `MessageBubbleView`, `APIConfiguration`, and `ModelManagementSheet` (91 tests), and backend contract enforcement for the three backends that were missing it.

## [0.4.0](https://github.com/roryford/BaseChatKit/compare/v0.3.10...v0.4.0) (2026-04-08)

**Public API surface cleanup for open-source release** — BaseChatKit previously exposed roughly a dozen internal implementation types as `public`, leaking details that external consumers should never depend on. This release narrows the public API to only the types, protocols, and services that framework consumers are meant to use, making the library safe to publish as a public Swift package.

Twelve types that existed solely to support internal cross-module wiring — GGUF metadata parsing (`GGUFMetadata`, `GGUFMetadataReader`, `GGUFReaderError`), prompt template detection (`PromptTemplateDetector`), tokenizer internals (`HeuristicTokenizer`, `CachingTokenizer`), SSE stream parsing (`SSEStreamParser`), compression strategy implementations (`AnchoredCompressor`, `ExtractiveCompressor`, `CompressionOrchestrator`), thermal pressure handling (`MemoryPressureHandler`), and the `withExponentialBackoff` convenience function — are now `package` or `internal` access. Types needed across BaseChatKit's own modules use Swift 5.9's `package` access level; types used only within `BaseChatCore` use `internal`. Consumer-facing types like `ModelContainerFactory` and `SwiftDataPersistenceProvider` remain `public` since the Example app and downstream projects instantiate them directly.

The unused direct dependency on `swift-transformers` (a transitive dependency of `mlx-swift-lm`) was removed, eliminating a build warning. Snapshot test reference files in `BaseChatSnapshotTests` are now excluded from the target, silencing the "25 unhandled files" warning. Six public API members that lacked documentation (`NetworkDiscoveryService.startDiscovery()`, `.stopDiscovery()`, `.probe(host:port:)`, `HuggingFaceService.init(hubClient:)`, `InferenceError.isRetryable`, `BackgroundDownloadManager.hasActiveDownloads`) received `///` doc comments. A stale screenshot placeholder comment was removed from the README. GitHub branch protection was updated to require one PR approval for merges to `main` ([#217](https://github.com/roryford/BaseChatKit/issues/217)).

### ⚠ Breaking changes

Downstream projects that reference any of the twelve internalized types by name will need to update. The affected types were never part of the intended public API, but code that imported them directly will see compile errors. If your project uses `HeuristicTokenizer`, `AnchoredCompressor`, `CompressionOrchestrator`, or `SSEStreamParser`, migrate to the public protocol equivalents (`TokenizerProvider`, `ContextCompressor`) or add `@testable import BaseChatCore` in test targets. `ModelContainerFactory` and `SwiftDataPersistenceProvider` remain public and require no changes.

## [0.3.10](https://github.com/roryford/BaseChatKit/compare/v0.3.9...v0.3.10) (2026-04-08)

### Features

**Full SwiftUI preview coverage and generation queue hardening** — Downstream consumers previously had to build and run the demo app to see how many BaseChatUI views rendered, since 12 of 28 views lacked Xcode canvas previews. Every view in the `BaseChatUI` module now ships with `#Preview` blocks covering key states (empty, populated, streaming, error), giving framework consumers instant visual feedback when integrating components. Self-contained views (SessionRowView, AssistantMarkdownView, MessagePartsView, ModelLoadingIndicatorView, StreamingCursorView, TypingIndicatorView) also have matching `.dump`-based snapshot tests for CI-friendly structural regression detection on both iOS and macOS. Environment-dependent views (ChatExportSheet, MessageActionMenu, SamplerPresetPickerView, ServerDiscoveryView, RemoteServerConfigSheet, SessionListView) get previews with minimal stub environments. The generation queue introduced in v0.3.8 received three correctness fixes from code review: `stopGeneration()` now sets the stream phase to `.failed("Cancelled")` before finishing continuations (previously left observers in a non-terminal state), `discardRequests(notMatching:)` passes a specific `InferenceError` instead of a generic `CancellationError` so thrown errors match the failure reason, and `generate()` is documented as the non-queued entry point for short-lived operations like title generation and compression. Snapshot test count increased from 13 to 25 ([#214](https://github.com/roryford/BaseChatKit/issues/214)).

## [0.3.9](https://github.com/roryford/BaseChatKit/compare/v0.3.8...v0.3.9) (2026-04-08)

### Features

**Real-device E2E test infrastructure** — The test suite previously relied entirely on mocks for backend validation: `MockInferenceBackend` faked token streams, and MLX tests injected a `MockMLXModelContainer` rather than loading real weights. This meant regressions in actual model loading, GPU inference, and HTTP streaming could pass the test suite undetected. Two new E2E test suites now exercise real backends on developer hardware. `OllamaE2ETests` hits a live local Ollama server, auto-discovers a model in the 7–8B parameter range via `/api/tags`, and runs six inference tests including streaming, system prompts, multi-turn generation, cancellation, and output token limits. `MLXModelE2ETests` loads real MLX model weights from disk, performs GPU-accelerated inference via Metal, and runs seven tests covering the same surface plus model reload. Both suites gate on hardware availability via `HardwareRequirements` — Ollama tests skip when no server is reachable, MLX tests skip without Apple Silicon or a Metal device. MLX E2E tests live in a dedicated `BaseChatMLXIntegrationTests` target because MLX's Metal shader library (metallib) is only compiled by Xcode's build system, not by `swift test`. The MLX trait is now default-enabled so Xcode resolves dependencies correctly; CI passes `--disable-default-traits` to avoid the metallib crash on headless runners. Unit tests for the new `HardwareRequirements` helpers (MLX directory validation, Ollama model selection) run in CI without hardware ([#213](https://github.com/roryford/BaseChatKit/issues/213)).

### Bug Fixes

**macOS model selection sheet rendered blank** — `ModelSelectTab` inside `ModelManagementSheet` displayed an empty view on macOS because the SwiftUI `Form` two-column layout pushed content outside the visible area. Fixed by applying the correct frame constraints for the macOS sheet presentation ([e483df9](https://github.com/roryford/BaseChatKit/commit/e483df9ec443163c5d0c48b8a62e166f712c009c)).

## [0.3.8](https://github.com/roryford/BaseChatKit/compare/v0.3.7...v0.3.8) (2026-04-08)

### Features

**Generation queue for multi-consumer inference** — `InferenceService` previously coordinated generation through a single `isGenerating` boolean, forcing secondary consumers (entity extraction, summarization, classification) to poll with `Task.sleep` before starting. It now manages a proper FIFO queue: `enqueue()` returns a `(GenerationRequestToken, GenerationStream)` immediately and the request executes when it reaches the front. Three priority levels (`.userInitiated`, `.normal`, `.background`) with FIFO within each level; max queue depth of 8. Background-priority requests are automatically dropped under serious or critical thermal pressure. `ChatViewModel` uses `.userInitiated` priority and suppresses the idle flash between queued generations via `hasQueuedRequests`. Session switches cancel stale requests via `discardRequests(notMatching:)`, and `stopGeneration()` drains the entire queue. Backends are untouched — all local backends (MLX, llama.cpp, Foundation) are single-generation by nature, so sequential queuing is the correct concurrency pattern. Closes [#204](https://github.com/roryford/BaseChatKit/issues/204) ([#209](https://github.com/roryford/BaseChatKit/issues/209)).

## [0.3.7](https://github.com/roryford/BaseChatKit/compare/v0.3.6...v0.3.7) (2026-04-07)


### Features

**Testable MLX generation and HuggingFace linker fix** — `MLXBackend.generate()` was completely untested: `ModelContainer` from `mlx-swift-lm` is a concrete class with no protocol, so there was no way to inject a mock without loading real weights on Apple Silicon. A new internal `MLXModelContainerProtocol` abstracts the two methods `MLXBackend` calls — `generate(messages:parameters:)` — and the real `ModelContainer` conforms via a one-line extension. `MLXBackend` now holds `any MLXModelContainerProtocol` and exposes a package-internal `_inject(_:)` method so tests can swap in a mock without touching production call sites. `MockMLXModelContainer` in `BaseChatTestSupport` yields injected token arrays, tracks call counts, and supports mid-stream cancellation with a tracked producer task wired to `continuation.onTermination` — making the cancellation test deterministic rather than racy. Five new tests run in CI without hardware: token streaming, output token limits, cancellation, error propagation from `generate()`, and a compile-time surface check for the `SendableLMInput` wrapper. The release also fixes a linker error (#205) that broke all test targets in downstream projects: `mlx-swift-lm 2.30.6` resolved a `swift-transformers` version whose transitive `HuggingFace.HubCache` symbols conflicted with the direct `swift-huggingface 0.9.0` pin. Updated to `mlx-swift 0.31.3`, `mlx-swift-lm 2.31.3`, and added `swift-transformers 1.2.0` as an explicit dependency ([#206](https://github.com/roryford/BaseChatKit/issues/206), closes [#205](https://github.com/roryford/BaseChatKit/issues/205)).

## [0.3.6](https://github.com/roryford/BaseChatKit/compare/v0.3.5...v0.3.6) (2026-04-07)

### Bug Fixes

**Swift 6.3 concurrency and SwiftData store collision fixes** — Swift 6.3 (released April 2026) tightened actor-isolation and `Sendable` enforcement in ways that produced compiler warnings across the framework, and CI (running Swift 6.0) rejected one pattern outright. `GenerationStream` is now a true `@MainActor`-isolated type — phase updates were already required on the main thread, so this matches the documented contract rather than changing it. All `setPhase` callsites in the cloud and local backends hop to `@MainActor` via `await MainActor.run { }`. Cloud backend subclasses (Claude, Kobold, Ollama, OpenAI) and `BackgroundDownloadManager` explicitly restate their `@unchecked Sendable` conformance, as Swift 6.3 requires subclasses to restate inherited conformances. `DeviceCapabilityService` replaces `UIDevice.current.model` — now `@MainActor`-isolated in Swift 6.3 — with `sysctl hw.machine` / `hw.model`, which is callable from any context. `StalledCallback.handler` is typed `(@Sendable () -> Void)?` so the Swift 6.0 region-based isolation checker can verify the weak capture of `GenerationStream` is safe. The demo app's SwiftData store is named `"BaseChatDemo"` to prevent it from writing to the generic `default.store` path shared by other apps, which caused an "unknown model version" crash on clean installs ([#203](https://github.com/roryford/BaseChatKit/issues/203)).

**SwiftData schema type alignment** — `memoryBytes` in `ModelBenchmarkCache` and its associated `ModelBenchmarkResult` struct used `UInt64` in one place and `Int64` in another. SwiftData hashes both to the same SQLite INTEGER column type, so no migration was needed, but the mismatch required explicit casting at every use site. Both are now consistently `Int64`.

## [0.3.5](https://github.com/roryford/BaseChatKit/compare/v0.3.4...v0.3.5) (2026-04-06)

### Features

**App-defined macros without forking the framework** — The macro system was a closed list: adding a domain-specific token like `{{chapterNumber}}` or `{{diceRoll}}` meant editing BaseChatKit itself, which made updating the dependency painful. Apps can now implement `MacroProvider` and register it at startup; the framework calls each provider in registration order and uses the first non-nil result, falling back to built-ins for standard tokens. The built-in set adds `{{modelName}}` and `{{messageCount}}`, both resolved automatically from the active session. The `{{roll:XdY}}` macro has moved out of core — it was specific to one consumer app and had no place in a generic framework; apps that need dice rolls register it themselves ([#103](https://github.com/roryford/BaseChatKit/issues/103)).

**Capability tiers in the model picker** — Choosing a model from the list required users to mentally translate file sizes and quantisation strings into a sense of what the model could do. `ModelInfo` now carries a capability tier — minimal, fast, balanced, capable, or frontier — estimated from file size and shown as a badge in the selection row. For apps that want measured data rather than estimates, `ModelBenchmarkRunner` provides a protocol and a default implementation that fires a short fixed prompt and records tokens per second; results are cached in SwiftData (schema v3) and survive app restart. Cloud model tiers are assigned statically at registration time and never require a benchmark run ([#104](https://github.com/roryford/BaseChatKit/issues/104)).

## [0.3.4](https://github.com/roryford/BaseChatKit/compare/v0.3.3...v0.3.4) (2026-04-06)

### Performance Improvements

**Faster generation on long conversations** — Each inference request previously re-tokenized every message in the history multiple times: the compression threshold check, the compressor, and prompt assembly all independently counted tokens for the same content. In a 50-message conversation this meant the same strings were processed three to five times before the first token was generated, with cost growing linearly with context length. The generation pipeline now shares a per-cycle token count cache so each unique string is tokenized exactly once regardless of how many subsystems need the count, and prompt assembly recovers its token totals as a byproduct of message trimming rather than making a separate pass. Time-to-first-token improves proportionally with conversation length. No API changes required ([#185](https://github.com/roryford/BaseChatKit/issues/185)).

## [0.3.3](https://github.com/roryford/BaseChatKit/compare/v0.3.2...v0.3.3) (2026-04-06)

### Features

**Backend reliability and streaming resilience overhaul** — Cloud backends could silently block for up to 20 minutes when servers stalled, models were evicted, or retries compounded against URLSession's 300-second timeout. This release introduces four structural refactors and addresses seven reliability issues ([#181](https://github.com/roryford/BaseChatKit/issues/181), [#182](https://github.com/roryford/BaseChatKit/issues/182), [#183](https://github.com/roryford/BaseChatKit/issues/183), [#184](https://github.com/roryford/BaseChatKit/issues/184), [#187](https://github.com/roryford/BaseChatKit/issues/187), [#188](https://github.com/roryford/BaseChatKit/issues/188), [#189](https://github.com/roryford/BaseChatKit/issues/189)).

`GenerationStream` separates content events from lifecycle state — consumers iterate `stream.events` for tokens while the UI observes `stream.phase` for connecting, streaming, stalled, retrying, and failed states without adding cases to `GenerationEvent`. The `.done` event case has been removed; stream termination is authoritative. `InferenceBackend.generate()` now returns `GenerationStream` instead of `AsyncThrowingStream<GenerationEvent, Error>`.

Retry is no longer opaque: `RetryStrategy` is a protocol with an injectable `ExponentialBackoffStrategy` default, and exhausted retries throw `RetryExhaustedError` wrapping the last error so callers can distinguish "failed after retries" from a single failure. Retry scope is narrowed to the HTTP connection phase only — mid-stream failures propagate immediately, preserving already-yielded tokens. The stream surfaces `.retrying(attempt:of:)` phase during retry attempts.

`URLSessionProvider` centralises session creation, eliminating four duplicated static session blocks and fixing ClaudeBackend's missing `timeoutIntervalForResource`. A `CircuitBreaker` actor with closed/open/halfOpen states is available for fast-failing repeatedly failing backends.

Idle stall detection fires `.stalled` at the midpoint of a configurable timeout and throws `CloudBackendError.timeout` at the full duration. `SSEStreamParser` no longer swallows I/O errors during cancellation, and now logs invalid UTF-8 byte sequences. `CloudBackendError.streamInterrupted` is split into `.streamInterrupted` (retryable) and `.backendDeallocated` (not retryable). OllamaBackend is migrated to an `SSECloudBackend` subclass and passes `keep_alive` (default 30 minutes) to reduce cold-start latency. ([#193](https://github.com/roryford/BaseChatKit/issues/193))

## [0.3.2](https://github.com/roryford/BaseChatKit/compare/v0.3.1...v0.3.2) (2026-04-06)


### Bug Fixes

**Compression system correctness** — Six bugs fixed in the context compression layer. `shouldCompress` now includes system prompt tokens in its utilization calculation, preventing late-triggering compression when the system prompt is large. The summary parser is now field-name-agnostic, so custom templates with underscored fields (e.g., `PLOT_THREADS`) are parsed correctly instead of silently dropping fields. `ExtractiveCompressor` caps candidate selection to the remaining budget after pinned messages, preventing over-budget output. Empty summaries from the LLM now fall back to extractive compression instead of injecting a useless `[Summary unavailable]` system message. A `Task.checkCancellation()` check before the inference call allows cancelled compressions to bail out early. ([#179](https://github.com/roryford/BaseChatKit/issues/179))

**CI crash from assertionFailure in debug builds** — `BaseChatSchemaV2`'s MessagePart encode/decode helpers used `assertionFailure` for recoverable conditions (malformed JSON, non-UTF-8 strings). These trap in debug builds including `swift test`, crashing the process with SIGTRAP (signal 5) even when all test assertions passed. Replaced with `Log.persistence` warnings so the existing fallback logic executes cleanly. Also fixed `ToolCall.parsedArguments()` where a `guard let` with `try` swallowed `JSONSerialization` errors as `CocoaError` instead of wrapping them in `ToolCallingError.invalidArguments`. ([#186](https://github.com/roryford/BaseChatKit/issues/186))

## [0.3.1](https://github.com/roryford/BaseChatKit/compare/v0.3.0...v0.3.1) (2026-04-06)

### Bug Fixes

**Test mocks aligned with GenerationEvent stream** — The v0.3.0 streaming API change (`AsyncThrowingStream<GenerationEvent, Error>`) left `MockInferenceBackend` and other test doubles still returning the old `String` stream signature, causing compilation failures in downstream test targets. All mocks in `BaseChatTestSupport` now return `GenerationEvent` streams. ([eff073a](https://github.com/roryford/BaseChatKit/commit/eff073ac763625982beda2819da54199532c6621))

## [0.3.0](https://github.com/roryford/BaseChatKit/compare/v0.2.22...v0.3.0) (2026-04-06)


### ⚠ BREAKING CHANGES

This release makes two foundational API changes that would be prohibitively expensive to ship after 1.0. Both are required to support multimodal messages, tool calling, and structured generation.

**Streaming API** — `InferenceBackend.generate()` now returns `AsyncThrowingStream<GenerationEvent, Error>` instead of `AsyncThrowingStream<String, Error>`. The new `GenerationEvent` enum carries `.token(String)`, `.toolCall(name:arguments:)`, `.usage(prompt:completion:)`, and `.done` cases. All backend conformers and stream consumers must update their `for try await` loops to switch on the event type. ([#167](https://github.com/roryford/BaseChatKit/issues/167), closes [#130](https://github.com/roryford/BaseChatKit/issues/130))

**Message content model** — `ChatMessage.content` is now a computed property that concatenates text parts from a new `contentParts: [MessagePart]` array. Writing to `content` still works (it replaces all parts with a single `.text`), so most consumer code is unaffected. However, direct SwiftData queries on the `content` column must use `contentPartsJSON` instead. A `BaseChatSchemaV2` migration automatically wraps existing content strings into `[.text(content)]`. ([#168](https://github.com/roryford/BaseChatKit/issues/168), closes [#131](https://github.com/roryford/BaseChatKit/issues/131))

### Features

**Tool calling and structured generation** — New `ToolProvider` protocol, `ToolCallingBackend` opt-in protocol, and `StructuredGenerationBackend` protocol with `generateStructured<T: Decodable>()`. `ClaudeBackend` handles Anthropic `tool_use` content blocks, `OpenAIBackend` handles OpenAI function-calling format. A `GrammarConstraint` type supports GBNF strings and JSON schema for constrained decoding. Tool call rounds are capped at 10 to prevent runaway loops. `InferenceService` and `ChatViewModel` wire tool providers through to conforming backends. ([#170](https://github.com/roryford/BaseChatKit/issues/170), closes [#55](https://github.com/roryford/BaseChatKit/issues/55))

## [0.2.22](https://github.com/roryford/BaseChatKit/compare/v0.2.21...v0.2.22) (2026-04-06)


### Bug Fixes

`BaseChatConfiguration.shared` and `CuratedModel.all` used `nonisolated(unsafe) static var` with a manual `NSLock`, which made it structurally possible to access the protected value without holding the lock. Both singletons now use `OSAllocatedUnfairLock`, which encapsulates the value inside the lock itself — unsynchronized access is a compile error rather than a discipline problem. ([#162](https://github.com/roryford/BaseChatKit/issues/162), closes [#156](https://github.com/roryford/BaseChatKit/issues/156))

MLX model downloads could fail silently when Hugging Face returned an HTML error page instead of a model snapshot, and the search filter allowed non-MLX model variants to appear in results. Downloads now validate response content types and snapshot structure before proceeding, and the search filter restricts results to MLX-compatible variants. ([#159](https://github.com/roryford/BaseChatKit/issues/159))

An audit of all 21 `@unchecked Sendable` conformances removed 8 that were unnecessary — redundant subclass declarations inherited from `SSECloudBackend`, `@MainActor`-isolated types that already satisfy `Sendable`, and test types with only immutable `Sendable` stored properties. The remaining 13 are legitimately needed for lock-guarded mutable state, C interop wrappers, and `@Observable` internals. ([#164](https://github.com/roryford/BaseChatKit/issues/164), closes [#150](https://github.com/roryford/BaseChatKit/issues/150))

## [0.2.21](https://github.com/roryford/BaseChatKit/compare/v0.2.20...v0.2.21) (2026-04-05)


### Bug Fixes

The `PinnedSessionDelegate` shipped with empty certificate pin sets for `api.anthropic.com` and `api.openai.com`. Although the delegate implemented fail-closed behavior, the missing pins meant TLS connections to these production hosts were always rejected — or, if pinning was bypassed, offered no MITM protection.

This release populates SPKI SHA-256 pins for the Google Trust Services WE1 intermediate CA and GTS Root R4 shared by both hosts. Intermediate/root pinning was chosen over leaf pinning because leaf certificates rotate every ~90 days, while intermediate CAs are stable across renewals. The chain validation logic was also updated to check all certificates in the TLS chain (leaf, intermediates, root) instead of only the leaf, which is required for intermediate-level pinning to work.

Pins are loaded automatically during `DefaultBackends.register(with:)` and respect any custom pins the host app has already configured — they will not be overwritten. Pin mismatch errors now log all seen SPKI hashes from the chain to aid rotation debugging. ([#157](https://github.com/roryford/BaseChatKit/issues/157))

## [0.2.20](https://github.com/roryford/BaseChatKit/compare/v0.2.19...v0.2.20) (2026-04-05)


### Features

* support MLX search and snapshot downloads ([#148](https://github.com/roryford/BaseChatKit/issues/148)) ([a9ae0c1](https://github.com/roryford/BaseChatKit/commit/a9ae0c124f9cbac0b687ff2252902d03976a08ce))

## [0.2.19](https://github.com/roryford/BaseChatKit/compare/v0.2.18...v0.2.19) (2026-04-05)


### Features

* add structured ChatError with recovery actions ([0c6c37e](https://github.com/roryford/BaseChatKit/commit/0c6c37ed8247fca779fc0a32cc9343816c654d30))


### Bug Fixes

* add Equatable to ChatError enums, preserve error context in surfaceError ([2752c70](https://github.com/roryford/BaseChatKit/commit/2752c70ea0fbe45e72c1d3c0ca4a4c99f8b1cd32))

## [0.2.18](https://github.com/roryford/BaseChatKit/compare/v0.2.17...v0.2.18) (2026-04-05)


### Bug Fixes

* reset isGenerating on synchronous backend throw, extend retry to all retryable errors ([6a9190f](https://github.com/roryford/BaseChatKit/commit/6a9190fd1a9c41ce46836440fa08ac9022868161))
* reset isGenerating on synchronous backend throw, extend retry to all retryable errors ([329294f](https://github.com/roryford/BaseChatKit/commit/329294fe07759eac3cb7884ea3117ce946cb1f01))
* update retry log message to reflect all retryable error types ([3351b6c](https://github.com/roryford/BaseChatKit/commit/3351b6ca266fcfcfc922c47a3f8ffe451593bee3))

## [0.2.17](https://github.com/roryford/BaseChatKit/compare/v0.2.16...v0.2.17) (2026-04-05)


### Features

* add backend capability API and host-facing settings surface ([#138](https://github.com/roryford/BaseChatKit/issues/138)) ([0b9affb](https://github.com/roryford/BaseChatKit/commit/0b9affb2957c10a007b56ac91abde731e86a4db5))

## [0.2.16](https://github.com/roryford/BaseChatKit/compare/v0.2.15...v0.2.16) (2026-04-05)


### Features

* add SwiftData VersionedSchema and MigrationPlan infrastructure ([#120](https://github.com/roryford/BaseChatKit/issues/120)) ([a065044](https://github.com/roryford/BaseChatKit/commit/a06504426b15b6a4384205cc879f4a937d25886f))
* extend BackendCapabilities with contextWindowSize and capability fields ([#125](https://github.com/roryford/BaseChatKit/issues/125)) ([5fe2038](https://github.com/roryford/BaseChatKit/commit/5fe2038357f698e496cc917ab88a70999ee859e4))

## [0.2.15](https://github.com/roryford/BaseChatKit/compare/v0.2.14...v0.2.15) (2026-04-05)


### Features

* add OpenAICompatibleBackend, OllamaBackend, and BonjourDiscoveryService for remote inference ([77360d7](https://github.com/roryford/BaseChatKit/commit/77360d7c5c1c9a95ca0280429ebc3f7b60412174))
* add PostGenerationTask hook to ChatViewModel ([5ad1837](https://github.com/roryford/BaseChatKit/commit/5ad183740622ce4c3673a64a45ecbe64e336bbf6))
* add PostGenerationTask hook to ChatViewModel ([ba1e38e](https://github.com/roryford/BaseChatKit/commit/ba1e38edf0a9e92b8351fbac5097f78ba9b3cb7f)), closes [#111](https://github.com/roryford/BaseChatKit/issues/111)
* add PromptSlotPosition enum replacing string-based slot positions ([1913a16](https://github.com/roryford/BaseChatKit/commit/1913a16d5b5e6216e789ec9ca6852804cd4f10dc))
* add PromptSlotPosition enum replacing string-based slot positions ([65b4bd4](https://github.com/roryford/BaseChatKit/commit/65b4bd4d12626782ab7f764c5fbd330be360a163))
* add remote inference backends (OpenAI-compatible, Ollama, KoboldCpp) ([85733a2](https://github.com/roryford/BaseChatKit/commit/85733a21a364b0c875ea210412dc8f8f39aea913))


### Bug Fixes

* address remaining PR 122 review issues ([989058e](https://github.com/roryford/BaseChatKit/commit/989058e4780f750a9601ec648547cd5104dfe98c))
* avoid sending self across actor boundary in post-generation error handler ([067c219](https://github.com/roryford/BaseChatKit/commit/067c2191c0c9b59545a243efb8a4263681768345))
* correct BonjourDiscovery re-probe, OllamaBackend UTF-8, save error handling, test cleanup ([bfa5bf7](https://github.com/roryford/BaseChatKit/commit/bfa5bf7db7941dac60daa6fa79b942961f834cd4))
* correct PromptSlotPosition sortIndex semantics and assembler sort stability ([ea7d0c9](https://github.com/roryford/BaseChatKit/commit/ea7d0c9b5c18a5500dd2a542fdb46a8bb71773f3))
* move backend loadModel off @MainActor to prevent UI blocking ([b553d83](https://github.com/roryford/BaseChatKit/commit/b553d8391f43bbf8d3388ea6fb1491aaea6d8c81))
* move backend loadModel off @MainActor to prevent UI blocking ([b553d83](https://github.com/roryford/BaseChatKit/commit/b553d8391f43bbf8d3388ea6fb1491aaea6d8c81))
* move backend loadModel off @MainActor to prevent UI blocking ([b0ae9ab](https://github.com/roryford/BaseChatKit/commit/b0ae9ab0677d767191d66914afa027fa390eab33)), closes [#100](https://github.com/roryford/BaseChatKit/issues/100)
* remove stale isRemote argument from BackendCapabilities call sites ([417d0e2](https://github.com/roryford/BaseChatKit/commit/417d0e28846d680af8082d332a6df65476a9e61e))
* use plain Task for post-generation hook, clear backgroundTaskError on new generation ([358630e](https://github.com/roryford/BaseChatKit/commit/358630e94838e10b2d1a26a0b7d560c09242610e))

## [0.2.14](https://github.com/roryford/BaseChatKit/compare/v0.2.13...v0.2.14) (2026-04-04)


### Bug Fixes

* harden model handoff lifecycle coordination ([fecf6f3](https://github.com/roryford/BaseChatKit/commit/fecf6f35610f5083babd6ce07d975e7e26b1a5a6))
* use UUID hostnames to eliminate MockURLProtocol cross-suite race ([#99](https://github.com/roryford/BaseChatKit/issues/99)) ([ed98813](https://github.com/roryford/BaseChatKit/commit/ed98813a0c1481d20d3f28a7ca8d8540510d358f))

## [0.2.13](https://github.com/roryford/BaseChatKit/compare/v0.2.12...v0.2.13) (2026-04-04)


### Bug Fixes

* avoid session restore selection clobber ([67a4194](https://github.com/roryford/BaseChatKit/commit/67a419467d8a2c881e9de5e28afeda36f35f678f))
* persist cloud endpoint selection and loading ([ef1d0d7](https://github.com/roryford/BaseChatKit/commit/ef1d0d7deaebbd01e482c581ffea40e940971439))
* persist cloud endpoint selection and loading ([c85097f](https://github.com/roryford/BaseChatKit/commit/c85097fdfa1a95c421449a32958ad024e37e6e83))

## [0.2.12](https://github.com/roryford/BaseChatKit/compare/v0.2.11...v0.2.12) (2026-04-04)


### Features

* add curated model presets to management sheet ([3573717](https://github.com/roryford/BaseChatKit/commit/3573717afbfaf0467bb424761c062461308cbc66))

## [0.2.11](https://github.com/roryford/BaseChatKit/compare/v0.2.10...v0.2.11) (2026-04-04)


### Bug Fixes

* correct macOS sheet layouts and add model selection E2E tests ([#90](https://github.com/roryford/BaseChatKit/issues/90)) ([19c127d](https://github.com/roryford/BaseChatKit/commit/19c127d6cdf0b2dd179bb35ae9cb4819438974ac))

## [0.2.10](https://github.com/roryford/BaseChatKit/compare/v0.2.9...v0.2.10) (2026-04-04)


### Features

* add pre-load memory gate to prevent OOM crashes ([#88](https://github.com/roryford/BaseChatKit/issues/88)) ([1cf37eb](https://github.com/roryford/BaseChatKit/commit/1cf37eb345787a5bbe265b8b47d27c4a82b7385e))

## [0.2.9](https://github.com/roryford/BaseChatKit/compare/v0.2.8...v0.2.9) (2026-04-03)


### Features

* extend BackendCapabilities and add activity indicators ([#85](https://github.com/roryford/BaseChatKit/issues/85)) ([ac0588d](https://github.com/roryford/BaseChatKit/commit/ac0588de88d52e55d231cd9e82179e28e4be5486))

## [0.2.8](https://github.com/roryford/BaseChatKit/compare/v0.2.7...v0.2.8) (2026-04-03)


### Bug Fixes

* address Copilot review comment on PR [#80](https://github.com/roryford/BaseChatKit/issues/80) ([906309d](https://github.com/roryford/BaseChatKit/commit/906309de7cc64dd4402be93ce18f148315e2b948))
* address Copilot review comments on PR [#75](https://github.com/roryford/BaseChatKit/issues/75) ([13dd499](https://github.com/roryford/BaseChatKit/commit/13dd499e65a42852dd2197260ce71ea68215fb84))
* address Copilot review comments on PR [#78](https://github.com/roryford/BaseChatKit/issues/78) ([15e1ecb](https://github.com/roryford/BaseChatKit/commit/15e1ecbecd18e15b59eb39a40f38b91fcedc0f20))
* address Copilot review comments on PR [#81](https://github.com/roryford/BaseChatKit/issues/81) ([1b28f2f](https://github.com/roryford/BaseChatKit/commit/1b28f2fa4f628a9493a6eaa62f1f8e5ebc872889))
* address Copilot review comments on PR [#82](https://github.com/roryford/BaseChatKit/issues/82) ([53f40ec](https://github.com/roryford/BaseChatKit/commit/53f40ec2473545e769ceb9cd6df2e1eb28bd3f89))
* address review findings in PR [#76](https://github.com/roryford/BaseChatKit/issues/76) ([17ffe65](https://github.com/roryford/BaseChatKit/commit/17ffe659ca7f9b843ef8ab100d0c2156da521141))
* address review findings in PR [#77](https://github.com/roryford/BaseChatKit/issues/77) ([3e12c10](https://github.com/roryford/BaseChatKit/commit/3e12c1053432376be8fc259d4afba4522283e8e3))
* address review findings in PR [#78](https://github.com/roryford/BaseChatKit/issues/78) ([04614e8](https://github.com/roryford/BaseChatKit/commit/04614e816eb686e0f9c81ca3000833ad50fc19bc))
* address review findings in PR [#80](https://github.com/roryford/BaseChatKit/issues/80) ([a8ff45e](https://github.com/roryford/BaseChatKit/commit/a8ff45eb64b677ed758f08b73c0339c764f7ac72))
* address review findings in PR [#81](https://github.com/roryford/BaseChatKit/issues/81) ([4dd66cd](https://github.com/roryford/BaseChatKit/commit/4dd66cd7b830e79f8f50530a63df247b2f114bce))
* address review findings in PR [#82](https://github.com/roryford/BaseChatKit/issues/82) ([7f7de44](https://github.com/roryford/BaseChatKit/commit/7f7de449015af9e5efd486e27b9490134ab59e91))
* convert E2E lifecycle tests to Swift Testing and fix review issues ([faf245c](https://github.com/roryford/BaseChatKit/commit/faf245c5e00054fb2971b75e1d5f5f563dcb2973))

## [0.2.7](https://github.com/roryford/BaseChatKit/compare/v0.2.6...v0.2.7) (2026-04-03)


### Features

* add max output token limit to generation pipeline ([#63](https://github.com/roryford/BaseChatKit/issues/63)) ([e4569c6](https://github.com/roryford/BaseChatKit/commit/e4569c6cabda6b33791c7dab7d0cdeaf55e2d00c))
* document and test stopGeneration() protocol contract ([#62](https://github.com/roryford/BaseChatKit/issues/62)) ([309e39c](https://github.com/roryford/BaseChatKit/commit/309e39c657fcb7efb4bf9dc70b7eb6574d9cdf6c))


### Bug Fixes

* reset FoundationBackend session after stop/cancel ([#61](https://github.com/roryford/BaseChatKit/issues/61)) ([055f232](https://github.com/roryford/BaseChatKit/commit/055f2327cae66d7c06d134d667984dc20cfbda82)), closes [#57](https://github.com/roryford/BaseChatKit/issues/57)
* stable reverse-scroll when prepending older messages ([#64](https://github.com/roryford/BaseChatKit/issues/64)) ([e858b6f](https://github.com/roryford/BaseChatKit/commit/e858b6fec50560d9c5528614d8d8e128c898292a))

## [0.2.6](https://github.com/roryford/BaseChatKit/compare/v0.2.5...v0.2.6) (2026-04-03)


### Features

* add focused example app scaffold with MinimalExample ([5db47a3](https://github.com/roryford/BaseChatKit/commit/5db47a3285d872c2bd6378673a02984743baf01a))
* add KoboldCpp backend and remote server discovery infrastructure ([d22cf42](https://github.com/roryford/BaseChatKit/commit/d22cf425805fab205edeba0c2a92271932a777ac))


### Bug Fixes

* replace deprecated configure(modelContext:) and remove phantom NarrationExample target ([0556fde](https://github.com/roryford/BaseChatKit/commit/0556fde31f648a471cda0bdd78219e02ebbe0f17))
* use GenerationConfig topK/typicalP and fix discovery stream race ([45cd524](https://github.com/roryford/BaseChatKit/commit/45cd524450906242178f29db647ce8130d8078cc))

## [0.2.5](https://github.com/roryford/BaseChatKit/compare/v0.2.4...v0.2.5) (2026-04-03)


### Performance Improvements

* throttle streamed token mutations in ChatViewModel ([#49](https://github.com/roryford/BaseChatKit/issues/49)) ([d57db57](https://github.com/roryford/BaseChatKit/commit/d57db57cd1557b5393398c5422a7321760c389fa))

## [0.2.4](https://github.com/roryford/BaseChatKit/compare/v0.2.3...v0.2.4) (2026-04-03)


### Features

* add RepetitionDetector and MacroExpander from an internal consumer app ([#50](https://github.com/roryford/BaseChatKit/issues/50)) ([311f9ae](https://github.com/roryford/BaseChatKit/commit/311f9ae974fdd48944a5d695e3770ad570747c70))
* migrate to Swift 6 language mode ([7704a77](https://github.com/roryford/BaseChatKit/commit/7704a7743e296a7f2e25eff64a53acc0da2e69cc))
* migrate to Swift 6 language mode ([8ce6dcc](https://github.com/roryford/BaseChatKit/commit/8ce6dccb9fcd2eb7bf804967b38ca7c4f0de41b1))


### Bug Fixes

* add local model import to model management ([69ef854](https://github.com/roryford/BaseChatKit/commit/69ef8545a570f73b021be94ace54cd706bea691a))
* add local model import to model management ([c32e497](https://github.com/roryford/BaseChatKit/commit/c32e4977c4261737894bb648305181f6a079e704))
* address Swift 6 test isolation and sendability ([2d3b1c3](https://github.com/roryford/BaseChatKit/commit/2d3b1c3eebb77005af54f36c9eeee277b3651db9))
* convert @MainActor test setUp/tearDown to async throws ([33d435c](https://github.com/roryford/BaseChatKit/commit/33d435c0ca45c1151ed5662028860b03dbec033d))
* replace [weak self] with [self] in TestSupport mock AsyncThrowingStream closures ([f332daf](https://github.com/roryford/BaseChatKit/commit/f332dafdf9b7ba194debf29d358dc1b02cbf33f1))
* resolve Swift 6 compile errors in MemoryPressureHandler and SettingsService ([e99e1db](https://github.com/roryford/BaseChatKit/commit/e99e1db11b9524a3d490d7ac336fa0cc2a1e01f6))
* revert SettingsService to [@unchecked](https://github.com/unchecked) Sendable ([0ce6684](https://github.com/roryford/BaseChatKit/commit/0ce6684b711992ebd887e2cf344daad01f7a7fdd))
* synchronize backend and global mutable state ([95bfbce](https://github.com/roryford/BaseChatKit/commit/95bfbce8de73ace6a3163bd8b96a140846425d72))

## [0.2.3](https://github.com/roryford/BaseChatKit/compare/v0.2.2...v0.2.3) (2026-04-01)


### Features

* harden security posture and expand CI smoke coverage ([#45](https://github.com/roryford/BaseChatKit/issues/45)) ([3101cb7](https://github.com/roryford/BaseChatKit/commit/3101cb739bc98f725a9b4a42da9a48a5c35af37b))


### Bug Fixes

* wire live model management services ([#41](https://github.com/roryford/BaseChatKit/issues/41)) ([063fe80](https://github.com/roryford/BaseChatKit/commit/063fe8004728006f5729a62572954ac4ddd428f2))

## [0.2.2](https://github.com/roryford/BaseChatKit/compare/v0.2.1...v0.2.2) (2026-03-31)


### Bug Fixes

* thread-safe pin store, CI-testable routing, Foundation probe audit, MLX docs ([#36](https://github.com/roryford/BaseChatKit/issues/36)) ([a83e42b](https://github.com/roryford/BaseChatKit/commit/a83e42bde14a85f579e922a12d3f1af92f0e000d))
* wire retry backoff into cloud backends and preserve partial Claude usage ([#34](https://github.com/roryford/BaseChatKit/issues/34)) ([679ad36](https://github.com/roryford/BaseChatKit/commit/679ad36579dba07ef8738d593c17090e408880e1))

## [0.2.1](https://github.com/roryford/BaseChatKit/compare/v0.2.0...v0.2.1) (2026-03-31)


### Features

* render markdown in assistant bubbles ([#31](https://github.com/roryford/BaseChatKit/issues/31)) ([dadc89e](https://github.com/roryford/BaseChatKit/commit/dadc89ed9d36b476c584c8296f657768a445e520))


### Bug Fixes

* move search field below tab picker and fix macOS tab switching in ModelManagementSheet ([#40](https://github.com/roryford/BaseChatKit/issues/40)) ([e54ad9f](https://github.com/roryford/BaseChatKit/commit/e54ad9f363578c16366dc1f2dbea8712de0ba367))

## [0.2.0](https://github.com/roryford/BaseChatKit/compare/v0.1.1...v0.2.0) (2026-03-30)


### ⚠ BREAKING CHANGES

* SessionManagerViewModel and ChatViewModel now require a ChatPersistenceProvider instead of accessing ModelContext directly. View models operate on ChatSessionRecord/ChatMessageRecord value types instead of SwiftData @Model objects. The deprecated configure(modelContext:) convenience is provided for migration.

### Features

* add ChatPersistenceProvider protocol to decouple from SwiftData ([1f26292](https://github.com/roryford/BaseChatKit/commit/1f2629281b414b8aa7d433e540d4597d0af58395)), closes [#4](https://github.com/roryford/BaseChatKit/issues/4)
* add Swift 6.1 package traits for selective backend compilation ([#22](https://github.com/roryford/BaseChatKit/issues/22)) ([be03548](https://github.com/roryford/BaseChatKit/commit/be0354874ad8ce87702dfc2c41b59fcb75f03f9c))


### Bug Fixes

* clarify hasFoundationModels checks OS version, not Apple Intelligence ([0f3314d](https://github.com/roryford/BaseChatKit/commit/0f3314def1a284595c2e45ed0ce726552d4da217))
* harden persistence error handling and state consistency ([a40bb5a](https://github.com/roryford/BaseChatKit/commit/a40bb5a9d5e5507b5bbe426e637673a7f309e50b))
* revert LlamaBackend lifecycle to NSLock — actor isolation unsafe in init/deinit ([ae141ae](https://github.com/roryford/BaseChatKit/commit/ae141ae348999e6ea6a5a4801bf734c3802c2e94))
* tighten SSE perf test expectation timeout from 10s to 5s ([fe4d57f](https://github.com/roryford/BaseChatKit/commit/fe4d57f8e095bc11f65e74ded1367f659ebdb71a))
* update perf test to use ChatMessageRecord after persistence refactor ([f16a8ab](https://github.com/roryford/BaseChatKit/commit/f16a8ab72796fa9ae7d2a37866eca0393ba4c00f))
* use updateMessage for edits and fix value-type test assertions ([a59dc4e](https://github.com/roryford/BaseChatKit/commit/a59dc4eafb7162d3811e8d61d77e9cd7bdbb90e9))

## 0.1.1 (2026-03-30)


### Bug Fixes

* use full=true instead of expand parameter for HuggingFace API ([cc7a131](https://github.com/roryford/BaseChatKit/commit/cc7a131dfd9c38baab1c2d3be80bc7936e629fd2))

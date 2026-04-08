# Changelog

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

**App-defined macros without forking the framework** — The macro system was a closed list: adding a domain-specific token like `{{chapterNumber}}` or `{{diceRoll}}` meant editing BaseChatKit itself, which made updating the dependency painful. Apps can now implement `MacroProvider` and register it at startup; the framework calls each provider in registration order and uses the first non-nil result, falling back to built-ins for standard tokens. The built-in set adds `{{modelName}}` and `{{messageCount}}`, both resolved automatically from the active session. The `{{roll:XdY}}` macro has moved out of core — it was Fireside-specific and had no place in a generic framework; apps that need dice rolls register it themselves ([#103](https://github.com/roryford/BaseChatKit/issues/103)).

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

* add RepetitionDetector and MacroExpander from Fireside ([#50](https://github.com/roryford/BaseChatKit/issues/50)) ([311f9ae](https://github.com/roryford/BaseChatKit/commit/311f9ae974fdd48944a5d695e3770ad570747c70))
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

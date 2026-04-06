# Changelog

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

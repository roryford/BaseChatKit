# Changelog

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

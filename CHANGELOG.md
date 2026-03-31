# Changelog

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

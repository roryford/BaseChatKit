# BaseChatKit — Claude Code Instructions

## Targets

| Target | Role | ML deps |
|--------|------|---------|
| `BaseChatInference` | Inference orchestration — protocols, models, services (no persistence) | None |
| `BaseChatCore` | SwiftData persistence — schema, `@Model` types, container, provider, export | None |
| `BaseChatBackends` | MLX, llama.cpp, Foundation, cloud backends (depends on `BaseChatInference`) | MLX, LlamaSwift |
| `BaseChatUI` | SwiftUI views and view models | None |
| `BaseChatTestSupport` | Shared mocks and fakes (`MockInferenceBackend`, `CharTokenizer`, etc.) | None |
| `BaseChatMLXIntegrationTests` | Xcode-only real MLX model E2E tests | MLX |

`BaseChatUI` depends only on `BaseChatCore` (and transitively `BaseChatInference`) — keep it that way. Never import `BaseChatBackends` from UI. `BaseChatBackends` depends on `BaseChatInference` directly, not `BaseChatCore`, so backend implementations stay free of SwiftData. Apps that only need inference orchestration can depend on `BaseChatInference` alone. `BaseChatCore` does **not** re-export `BaseChatInference` — files that use `InferenceService` or other inference types directly must `import BaseChatInference` explicitly.

## Running tests

```bash
# Runs in CI — no hardware required (disable default MLX trait to skip heavy deps)
swift test --filter BaseChatCoreTests --disable-default-traits
swift test --filter BaseChatInferenceTests --disable-default-traits
swift test --filter BaseChatUITests --disable-default-traits
swift test --filter BaseChatBackendsTests --disable-default-traits

# Apple Silicon only — MLX mock tests + llama.cpp
swift test --filter BaseChatBackendsTests --traits MLX,Llama
swift test --filter BaseChatE2ETests --disable-default-traits

# Xcode-only — real MLX model inference (metallib required)
# Cannot run via swift test; MLX Metal shaders are only compiled by Xcode.
xcodebuild test -scheme BaseChatKit-Package -only-testing BaseChatMLXIntegrationTests -destination 'platform=macOS'

# Example app UI tests — prefer build-for-testing once, then targeted reruns
scripts/example-ui-tests.sh build-for-testing
scripts/example-ui-tests.sh test-without-building -only-testing:BaseChatDemoUITests/ChatFlowUITests/testEmptyStateShowsWelcome

# Real Ollama server E2E (requires Ollama running at localhost:11434)
swift test --filter OllamaE2ETests --disable-default-traits
```

When writing hardware-gated tests, add `XCTSkipIf` guards at the top of the test rather than assuming the environment.

## Test conventions

- Use `XCTestCase` for new tests (existing Swift Testing suites use `@Suite`/`@Test` — match the file you're editing).
- Tests must honestly reflect their classification: a test that hits SwiftData is an integration test, not a unit test. Name and place it accordingly.
- Do not mock the persistence layer to make tests faster. Use in-memory SwiftData stores.
- Async tests: use real `async/await`, not `XCTestExpectation` wrappers unless testing callback-based code. Avoid artificial `sleep` or fixed timeouts — instead use `XCTestExpectation` / `XCTWaiter` with tight deadlines for callback-based code.
- After asserting an expected outcome, add a sabotage check: temporarily break the code path being tested and confirm the test fails. Remove the sabotage before committing.
- Performance tests use `measure { }` (XCTMeasure). Build all fixtures before the measure block.
- `withKnownIssue` is test debt, not a fix. Every use must have a `// FIXME: <issue URL>` comment on the line above. Remove the wrapper in the same PR that fixes the underlying bug. Never use it in critical E2E paths — see [TESTING.md §withKnownIssue Policy](TESTING.md#withknownissue-policy).

## Service sharing

`ChatViewModel.inferenceService` is `internal` by design. Apps that need the same `InferenceService` instance in multiple components (e.g., a story engine, character creator) should create it at the app level and inject it:

```swift
let inference = InferenceService()
let chatVM = ChatViewModel(inferenceService: inference)
let storyStore = StoryStore(inferenceService: inference)
```

Do not widen `inferenceService` to `public` — it exposes load coordination internals and makes `InferenceService`'s full API part of `ChatViewModel`'s public contract.

## Coding conventions

- **Concurrency**: async/await throughout. No Combine, no callback pyramids.
- **Observable state**: `@Observable` + `@MainActor`. Not `ObservableObject`/`@Published`.
- **Persistence**: SwiftData only. No CoreData.
- **Error handling**: only validate at system boundaries (user input, external APIs, file I/O). Don't add defensive guards for internal invariants that Swift's type system already enforces.
- **Comments**: explain *why*, not *what*. Omit when the code is self-evident.

## Hardware constraints (simulator / CI)

- `LlamaBackend` uses a global `llama_backend_init` — only one instance can exist per process. Tests must share a single instance or use `MockInferenceBackend`.
- Metal is unavailable in the simulator. Any test that touches `MLXBackend` or `LlamaBackend` will fail in CI — gate with `XCTSkipIf`.
- `FoundationBackend` requires iOS 26 / macOS 26. Gate accordingly.
- Context window is capped at 512 tokens in the simulator to avoid OOM.

## Pre-push checklist

Before pushing any branch, run all three CI test suites locally and confirm zero failures:

```bash
swift test --filter BaseChatCoreTests --disable-default-traits && swift test --filter BaseChatInferenceTests --disable-default-traits && swift test --filter BaseChatUITests --disable-default-traits && swift test --filter BaseChatBackendsTests --disable-default-traits
```

Never push based on a subset passing. After rebasing, always re-run the full suite before pushing — conflicts can silently break tests that compiled fine before.

When changing behavior of any function or type, grep for ALL test references across the entire `Tests/` directory, not just the obvious test file. Behavior changes require updating every test that asserts on the old behavior:

```bash
grep -r "functionOrTypeName" Tests/
```

CI runs on macOS (10x billing multiplier). Each failed push wastes ~25 billed minutes. Test locally first.

## Error handling in recoverable paths

Never use `assertionFailure` or `fatalError` for conditions that have fallback logic. These trap in debug builds (including `swift test`), crashing the test process even when tests pass. Use `Log.*` warnings instead. Reserve `assertionFailure` for true programmer errors with no recovery path.

## Commit style

This repo uses Conventional Commits. Release Please reads these to determine version bumps and generate the changelog.

```
feat: add streaming cancellation to FoundationBackend
fix: prevent context overflow when system prompt exceeds budget
perf: cache tokenizer lookups in ContextWindowManager
test: add XCTMeasure baselines for trimMessages hot path
chore: update mlx-swift-lm to 2.31.0
docs: clarify TokenizerProvider fallback behaviour
```

- `feat` → MINOR bump
- `fix` → PATCH bump
- Everything else → no release
- `BREAKING CHANGE:` in the commit footer → MAJOR bump

PR titles must follow the same format (enforced by CI).

## Release workflow

Release Please auto-creates a release PR after `feat:` or `fix:` merges. The auto-generated changelog is a one-liner — **it must be rewritten with prose before merging**. A pre-merge hook blocks the merge until this is done.

1. Release Please opens PR titled `chore(main): release X.Y.Z`
2. Check out the release branch: `git checkout release-please--branches--main`
3. Rewrite the CHANGELOG.md entry: **Bold title** — problem, what changed, why it matters. Use the `## Release Note` sections from the included feature PRs as source material.
4. Amend the commit and force-push: `git commit --amend --no-edit && git push --force`
5. Merge the release PR
6. Verify the GitHub release notes match (edit with `gh release edit` if needed)

For `feat:` and `fix:` PRs, write the changelog prose in the `## Release Note` section of the PR body at PR creation time, when context is fresh. This is the source material for step 3.

## PR workflow

All changes go through PRs — direct pushes to `main` are blocked for everyone.

1. Branch off `main`
2. Write code, commit with conventional commits
3. Open a PR: `gh pr create --title "feat: ..." --body "..."`
4. Report the PR URL — the maintainer reviews and merges manually
5. Do NOT pass `--auto` or `--merge` — merges require human approval

CI must pass (`BaseChatCoreTests` + `BaseChatInferenceTests` + `BaseChatUITests` + `BaseChatBackendsTests`) before merge is allowed.

`BaseChatBackendsTests` runs in CI without hardware traits — only cloud backend and SSE tests execute; MLX and Llama tests are excluded by `#if MLX`/`#if Llama` conditional compilation. Run with `--traits MLX,Llama` locally on Apple Silicon before merging backend changes. `BaseChatE2ETests` requires physical hardware and does not run in CI.

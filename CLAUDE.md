# BaseChatKit — Claude Code Instructions

## Targets

| Target | Role | ML deps |
|--------|------|---------|
| `BaseChatCore` | Models, protocols, services | None |
| `BaseChatBackends` | MLX, llama.cpp, Foundation, cloud backends | MLX, LlamaSwift |
| `BaseChatUI` | SwiftUI views and view models | None |
| `BaseChatTestSupport` | Shared mocks and fakes (`MockInferenceBackend`, `CharTokenizer`, etc.) | None |

`BaseChatUI` depends only on `BaseChatCore` — keep it that way. Never import `BaseChatBackends` from UI.

## Running tests

```bash
# Runs in CI — no hardware required
swift test --filter BaseChatCoreTests
swift test --filter BaseChatUITests
swift test --filter BaseChatBackendsTests   # cloud/SSE tests only; MLX and Llama excluded by #if traits

# Apple Silicon only — MLX, llama.cpp, on-device models
swift test --filter BaseChatBackendsTests --traits MLX,Llama
swift test --filter BaseChatE2ETests
```

When writing hardware-gated tests, add `XCTSkipIf` guards at the top of the test rather than assuming the environment.

## Test conventions

- Use `XCTestCase` for new tests (existing Swift Testing suites use `@Suite`/`@Test` — match the file you're editing).
- Tests must honestly reflect their classification: a test that hits SwiftData is an integration test, not a unit test. Name and place it accordingly.
- Do not mock the persistence layer to make tests faster. Use in-memory SwiftData stores.
- Async tests: use real `async/await`, not `XCTestExpectation` wrappers unless testing callback-based code. Avoid artificial `sleep` or fixed timeouts — instead use `XCTestExpectation` / `XCTWaiter` with tight deadlines for callback-based code.
- After asserting an expected outcome, add a sabotage check: temporarily break the code path being tested and confirm the test fails. Remove the sabotage before committing.
- Performance tests use `measure { }` (XCTMeasure). Build all fixtures before the measure block.

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

## Commit style

This repo uses Conventional Commits. Release Please reads these to determine version bumps and generate the changelog.

```
feat: add streaming cancellation to FoundationBackend
fix: prevent context overflow when system prompt exceeds budget
perf: precompute keyword densities in ExtractiveCompressor
test: add XCTMeasure baselines for trimMessages hot path
chore: update mlx-swift-lm to 2.31.0
docs: clarify TokenizerProvider fallback behaviour
```

- `feat` → MINOR bump
- `fix` → PATCH bump
- Everything else → no release
- `BREAKING CHANGE:` in the commit footer → MAJOR bump

PR titles must follow the same format (enforced by CI).

## PR workflow

All changes go through PRs — direct pushes to `main` are blocked for everyone.

1. Branch off `main`
2. Write code, commit with conventional commits
3. Open a PR: `gh pr create --title "feat: ..." --body "..."`
4. Report the PR URL — the maintainer reviews and merges manually
5. Do NOT pass `--auto` or `--merge` — merges require human approval

CI must pass (`BaseChatCoreTests` + `BaseChatUITests` + `BaseChatBackendsTests`) before merge is allowed.

`BaseChatBackendsTests` runs in CI without hardware traits — only cloud backend and SSE tests execute; MLX and Llama tests are excluded by `#if MLX`/`#if Llama` conditional compilation. Run with `--traits MLX,Llama` locally on Apple Silicon before merging backend changes. `BaseChatE2ETests` requires physical hardware and does not run in CI.

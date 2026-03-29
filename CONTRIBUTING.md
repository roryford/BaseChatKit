# Contributing to BaseChatKit

Thank you for your interest in contributing. This guide covers everything you need to get started.

## Getting Started

```bash
git clone https://github.com/roryford/BaseChatKit.git
cd BaseChatKit
swift build
swift test
```

`swift build` will resolve package dependencies on first run. `BaseChatBackends` pulls in MLX xcframeworks, so the initial fetch may take a moment.

## Project Structure

| Target | Purpose |
|--------|---------|
| **BaseChatCore** | Models, protocols, and services. No ML dependencies. This is the integration point for all backends and custom extensions. |
| **BaseChatBackends** | Concrete inference backend implementations: MLX, llama.cpp, Apple Foundation Models, and cloud APIs. Depends on heavy binary deps; requires Apple Silicon for MLX. |
| **BaseChatUI** | SwiftUI views and view models. Depends only on BaseChatCore — keeps the UI layer decoupled from ML runtimes. |
| **BaseChatTestSupport** | Shared mocks, fakes, and test helpers. Depended on by all test targets. |

## Running Tests

Test targets fall into two groups:

### No special hardware required

These run on any Mac (including Intel) and in CI:

```bash
swift test --filter BaseChatCoreTests
swift test --filter BaseChatUITests
```

### Requires Apple Silicon / real device

These targets link against MLX xcframeworks or exercise on-device models and will not build or run correctly on Intel Macs or simulators:

- **BaseChatBackendsTests** — MLXBackend, LlamaBackend, FoundationBackend
- **BaseChatE2ETests** — Full generation round-trips against real backends

Run them on Apple Silicon:

```bash
swift test --filter BaseChatBackendsTests
swift test --filter BaseChatE2ETests
```

To run everything at once on a capable machine:

```bash
swift test
```

## Adding a New Backend

1. Implement the `InferenceBackend` protocol (defined in `Sources/BaseChatCore`).
2. If your backend wraps a C or Objective-C library, mark the class `@unchecked Sendable`. Swift cannot verify the thread-safety invariants of C-backed state, so you are responsible for enforcing them manually (typically with a serial dispatch queue or actor isolation boundary).
3. Register your backend with `InferenceService.registerBackendFactory(_:)` at startup.
4. Add unit tests in `BaseChatBackendsTests` (or `BaseChatCoreTests` if the logic lives in Core). Hardware-gated tests belong in `BaseChatE2ETests`.

See existing backends in `Sources/BaseChatBackends` for reference implementations.

## Coding Conventions

- **Concurrency** — use async/await throughout. Do not introduce Combine publishers or callback-based APIs.
- **Observable state** — mark view models and services that publish state with `@MainActor`. Use `@Observable` (the macro from Observation framework), not `ObservableObject`/`@Published`.
- **Persistence** — use SwiftData. Do not introduce CoreData.
- **Comments** — omit comments unless the logic is genuinely non-obvious. The code should be readable without them. When a comment is warranted, explain *why*, not *what*.
- **Formatting** — follow the existing indentation (4-space, no tabs). There is no enforced formatter in CI yet; match the surrounding code.

## Commit Style

Use a short imperative subject line (50 characters or fewer):

```
Fix FoundationBackend generate() failing after session switch
```

Add a body when the *why* needs explanation — omit it when the subject line is self-sufficient. Do not describe what the diff already shows.

```
Fix FoundationBackend generate() failing after session switch

The backend held a stale session reference after switchToSession() was
called. Invalidate the cached session on unload so the next generate()
call forces a fresh probe.
```

## Pull Request Process

- Keep PRs focused on a single concern. Unrelated fixes belong in separate PRs.
- Add tests for new behaviour. If you are fixing a bug, add a test that fails before your fix and passes after.
- E2E tests that require Apple Silicon are acceptable without CI coverage — note the hardware requirement in the PR description.
- Update the relevant section of the README if your change affects the public API or integration steps.
- Request review from a maintainer. PRs are merged once at least one approval is received and all CI checks pass.

## Reporting Bugs

Open a GitHub Issue and select the **Bug Report** template. Include:

- A minimal reproduction case
- The platform and OS version (e.g. macOS 15.4, Apple M3)
- The Swift and Xcode versions (`swift --version`, `xcodebuild -version`)
- Relevant log output

## Feature Requests

Open a GitHub Issue and select the **Feature Request** template. Describe the problem you are solving, not just the solution you have in mind.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE) that covers this project.

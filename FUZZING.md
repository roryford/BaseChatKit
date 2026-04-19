# Fuzzing Guide

BaseChatFuzz is a long-running, randomised exercise harness for the inference stack. It drives real backends with semi-random prompts, sampler settings, and stop conditions, and runs detectors over the output stream looking for whole classes of bugs that unit tests don't think to ask about — visible reasoning leaks, runaway loops, template-token escapes, KV cache collisions, and so on. It is **not** a regression-test replacement: detector hits are leads to investigate, and severity stays at `flaky` until the calibration corpus lands.

On its first real-model smoke run against `qwen3.5:4b` via Ollama, the harness landed three findings in three iterations — every one a 41–99-second compute that produced an empty assistant message. Root cause was filed as [#487](https://github.com/roryford/BaseChatKit/issues/487): `OllamaBackend.extractToken` only reads `message.content` and silently drops the separate `thinking` field that reasoning models emit. That is the kind of bug this harness exists to find — a real production-path drop that no unit test was asking about, surfaced in minutes against an off-the-shelf model.

---

## Table of Contents

- [Quickstart](#quickstart)
- [Backends](#backends)
- [Anatomy of a Finding](#anatomy-of-a-finding)
- [Day-One Detectors](#day-one-detectors)
- [Reproducing a Finding](#reproducing-a-finding)
- [Adding a New Detector](#adding-a-new-detector)
- [Real-Bug Rediscovery Recipes](#real-bug-rediscovery-recipes)
- [Known Gaps](#known-gaps)

---

## Quickstart

Five-minute Ollama run, default detector set, defaults on everything else:

```bash
scripts/fuzz.sh --minutes 5
```

The wrapper prints a preflight line showing which backends it found (Llama via `~/Documents/Models/`, MLX via `~/Documents/Models/`, Ollama via `localhost:11434`, Foundation via `sw_vers`). If nothing is usable it exits with install hints. The recommended first model is `qwen3.5:4b` — it is a reasoning model and is the most likely to surface fuzzer-relevant behavior on a fresh machine (`ollama pull qwen3.5:4b`).

Direct invocation works too — the wrapper just adds the preflight and the `--with-mlx` extension:

```bash
swift run fuzz-chat --minutes 5
swift run fuzz-chat --iterations 200 --backend ollama --quiet
swift run fuzz-chat --single --seed 42 --model qwen3.5
```

Common flags:

| Flag | Purpose |
|------|---------|
| `--backend <name>` | `ollama` (default), `llama`, `foundation`, `mlx`, `all`. Only `ollama` is wired in v1. |
| `--minutes N` | Wall-clock budget. Default 5. |
| `--iterations N` | Iteration cap; runs until either budget is hit. |
| `--single` | One iteration then exit — useful with `--seed`. |
| `--seed N` | Deterministic prompt/sampler selection for repro. |
| `--model <substr>` | Restrict to models matching the substring. |
| `--detector <ids>` | Comma-separated detector IDs to enable. |
| `--quiet` | Suppress the per-iteration log line. |

---

## Backends

| Backend | Status | Discovery | Notes |
|---------|--------|-----------|-------|
| Ollama | Wired | `curl http://localhost:11434/api/tags` | Default backend in v1. |
| Llama  | Throws | `~/Documents/Models/**/*.gguf` via `HardwareRequirements` | Backend selection plumbed but not yet wired into the runner. |
| MLX    | Throws | `~/Documents/Models/<dir>/{config.json,*.safetensors,tokenizer.*}` | Requires the xcodebuild path because MLX Metal shaders only compile under Xcode — see `--with-mlx` below. |
| Foundation Models | Throws | `sw_vers -productVersion >= 26` | macOS 26+ only. |

Backend wiring lives behind a closure rather than a protocol today. `FuzzRunner.BackendProvider` is `() async throws -> FuzzRunner.BackendHandle`, where `BackendHandle` carries `(backend: any InferenceBackend, modelId: String, modelURL: URL, backendName: String, templateMarkers: RunRecord.MarkerSnapshot)`. To plug a new backend in, build a closure that constructs and configures the backend, returns the handle, and pass it to `FuzzRunner(config:backendProvider:)` — see `FuzzChatCLI.makeOllamaHandle` for the canonical example. Detectors operate on the resulting `RunRecord` and don't care which backend produced it. Issue [#496](https://github.com/roryford/BaseChatKit/issues/496) tracks promoting the closure into a proper `BackendDriver` protocol once a second backend is wired.

### MLX via xcodebuild

`swift run fuzz-chat --backend mlx` cannot work directly because MLX's Metal shaders are not compiled by SwiftPM. The wrapper's `--with-mlx` flag runs the MLX XCTest fuzz suite separately:

```bash
scripts/fuzz.sh --with-mlx --minutes 5
```

This invokes `xcodebuild test -scheme BaseChatKit-Package -only-testing BaseChatFuzzTests/MLXFuzzTests` after the swift-run path completes.

---

## Anatomy of a Finding

All output lands under `tmp/fuzz/` (gitignored). Each run appends to the index without clearing prior findings.

```
tmp/fuzz/
├── INDEX.md                       # Human-readable table: detector, hash, model, severity
├── index.json                     # Machine-readable equivalent for tooling
└── findings/
    └── <detector-id>/
        └── <hash>/
            ├── record.json        # Full event stream + sampler config + seed
            ├── summary.txt        # Human-readable triage summary
            └── repro.sh           # Single-command repro
```

Findings are deduplicated by `<hash>` — the same bug surfaced twice in one run shows up once. Open `tmp/fuzz/INDEX.md` after a run to triage.

---

## Day-One Detectors

Three detectors ship with the v1 harness. All are classified `flaky` until a calibration corpus rules out false positives on known-good outputs.

| ID | Sub-checks | Inspiration |
|----|-----------|-------------|
| `thinking-classification` | 4 | df94418 — `<think>...</think>` reasoning blocks were leaking into visible MLX/Llama output. |
| `looping` | 2 | qwen3.5:4b on Ollama — model gets stuck repeating phrases inside `<think>` blocks until max-tokens. |
| `empty-output-after-work` | `silent-empty` | [#487](https://github.com/roryford/BaseChatKit/issues/487) — `OllamaBackend.extractToken` drops the `thinking` field for reasoning models, leaving the user with a long compute and an empty assistant bubble. The headline first-day discovery. |

The remaining seven detectors and the calibration corpus are tracked as follow-up issues — see [Known Gaps](#known-gaps).

---

## Reproducing a Finding

Every finding directory ships an auto-generated `repro.sh`. It re-runs the harness with the original seed and model substring as a single iteration:

```bash
bash tmp/fuzz/findings/<detector-id>/<hash>/repro.sh
# expands to:
swift run fuzz-chat --seed <N> --model <substr> --single
```

Determinism caveat: the seed pins prompt and sampler selection, but real backends (Ollama, MLX, Llama) don't expose a sampling seed today, so token-level reproduction is best-effort. A `--replay` mode that reloads the full `record.json` and bypasses sampling is tracked as a follow-up — see [Known Gaps](#known-gaps).

---

## Adding a New Detector

Detectors live in `Sources/BaseChatFuzz/Detectors/`. Each conforms to the `Detector` protocol — one ID, a human-readable name, an inspiration string, and an `inspect(_ record: RunRecord) -> [Finding]` function. Register the new type in `DetectorRegistry.all`. See `EmptyOutputAfterWorkDetector.swift` for a worked example.

```swift
import Foundation

public struct MyDetector: Detector {
    public let id = "my-detector"
    public let humanName = "Short human-readable description"
    public let inspiredBy = "Issue #NNN or commit hash that motivated this check"

    public init() {}

    public func inspect(_ record: RunRecord) -> [Finding] {
        // Walk record.events / record.rendered / record.thinkingRaw / record.timing.
        // Return a Finding for each suspicious pattern; return [] when nothing fires.
        return []
    }
}
```

Then in `DetectorRegistry.swift`:

```swift
public static let all: [any Detector] = [
    ThinkingClassificationDetector(),
    LoopingDetector(),
    EmptyOutputAfterWorkDetector(),
    MyDetector(),   // ← add here
]
```

Run with `--detector my-detector` to test in isolation. A detector that fires on every iteration is almost certainly mis-tuned — verify against the calibration corpus before relying on it.

---

## Real-Bug Rediscovery Recipes

These verify the harness can rediscover known-fixed bugs. Use them as a sanity check after detector changes.

### Visible-text leak (thinking-classification)

```bash
git revert df94418
swift build
scripts/fuzz.sh --minutes 5 --detector thinking-classification
git revert HEAD   # restore the fix
```

The reverted state ships raw `<think>...</think>` content in the visible message stream. The `thinking-classification` detector should fire within the first few iterations against any reasoning-capable model.

### Looping inside think blocks (looping)

```bash
scripts/fuzz.sh --minutes 5 --model qwen3.5:4b --detector looping
```

`qwen3.5:4b` on Ollama is the canonical reproducer — it gets stuck repeating phrases inside `<think>` and exhausts max-tokens. The `looping` detector should hit consistently against this model with default sampler.

### Silent-empty Ollama output (empty-output-after-work)

```bash
scripts/fuzz.sh --minutes 5 --model qwen3.5:4b --detector empty-output-after-work
```

Until [#487](https://github.com/roryford/BaseChatKit/issues/487) is fixed, this fires reliably against any reasoning model on Ollama: the backend swallows the `thinking` stream, generation completes cleanly with no error, and the user sees a long compute followed by an empty bubble.

---

## Known Gaps

These are wired but not yet implemented. Day-one issues will be filed for each.

### Detectors not yet implemented (7)

| ID | Looks for |
|----|-----------|
| `template-token-leak` | Raw chat-template tokens (`<|im_start|>`, `<|eot_id|>`, etc.) appearing in visible output. |
| `memory-growth` | RSS increase across iterations beyond a baseline ceiling. |
| `kv-collision` | Output that looks like context bleed from a prior session. |
| `empty-visible-after-think` | `<think>` block followed by no visible content. |
| `race-stall` | First-token latency spike after rapid session switches. |
| `context-exhaustion-silent` | Truncation past the context window without a user-visible signal. |
| `timeout` | Generations that exceed the configured per-iteration deadline. |

### Infrastructure

- **Calibration corpus** — known-good outputs to score detectors against; gates the `flaky` → `confirmed` severity promotion.
- **`--replay <hash>`** — reload `record.json`, bypass sampling, and re-issue the exact recorded request for true bit-level reproduction.
- **`--shrink`** — minimise a failing prompt to the smallest input that still fires the detector.
- **Multi-turn** — current harness fuzzes single-turn only; multi-turn would surface KV-collision and session-isolation bugs the single-turn path can't see.
- **Slash command** — `/fuzz` shortcut to run `scripts/fuzz.sh` from inside Claude Code.
- **`BackendDriver` protocol** — promote `FuzzRunner.BackendProvider` from a closure to a protocol once a second backend is wired ([#496](https://github.com/roryford/BaseChatKit/issues/496)).

The fuzzer does not run in CI by design — it's a pre-release activity, not a gate.

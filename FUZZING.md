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

Backend wiring lives behind the `FuzzBackendFactory` protocol. A factory exposes `makeHandle() async throws -> FuzzRunner.BackendHandle`, where `BackendHandle` carries `(backend: any InferenceBackend, modelId: String, modelURL: URL, backendName: String, templateMarkers: RunRecord.MarkerSnapshot)`. To plug a new backend in, conform a `Sendable` struct to `FuzzBackendFactory` and pass it to `FuzzRunner(config:factory:)` — see `OllamaFuzzFactory` in `Sources/fuzz-chat/` for the canonical example. Detectors operate on the resulting `RunRecord` and don't care which backend produced it. Llama, Foundation, and MLX factory conformances are tracked in [#501](https://github.com/roryford/BaseChatKit/issues/501).

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
- **Multi-backend factory fleet** — `FuzzRunner` now accepts a `FuzzBackendFactory` protocol (landed via [#496](https://github.com/roryford/BaseChatKit/issues/496)). Ship `LlamaFuzzFactory`, `FoundationFuzzFactory`, and `MLXFuzzFactory` to feed `--backend all` ([#501](https://github.com/roryford/BaseChatKit/issues/501)).

The fuzzer does not run in CI by design — it's a pre-release activity, not a gate.

---

## Backend fixture coverage — audit 2026-04-19

Rationale: [#487](https://github.com/roryford/BaseChatKit/issues/487) — OllamaBackend silently dropped `message.thinking` because `OllamaBackendTests` had zero fixtures with that field. This matrix audits which protocol fields every backend has a fixture for and which it does not, so each `no` cell becomes a tracked follow-up rather than a latent "surfaced-by-the-fuzzer" bug. Source: [#503](https://github.com/roryford/BaseChatKit/issues/503).

**Legend.** `yes` — a fixture in `Tests/BaseChatBackendsTests/` asserts the field's behaviour. `no` — no fixture anywhere in the test tree exercises the field. `partial` — a fixture touches the field but does not cover the variants called out in the gap issue. Cells marked `n/a` apply when the field is structurally impossible on that backend (e.g. GGUF chat templates on Claude).

### Ollama

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| Ollama | `/api/chat` NDJSON happy path | yes | `OllamaBackendTests.swift:101` (`streaming_yieldsTokens`) | — |
| Ollama | `message.content` extraction | yes | `OllamaBackendTests.swift:328` (`extractToken_parsesContent`) | — |
| Ollama | `message.thinking` field | no | — | [#487](https://github.com/roryford/BaseChatKit/issues/487) |
| Ollama | `done_reason` variants (`stop`/`length`/`load`/`unload`) | no | — | [#507](https://github.com/roryford/BaseChatKit/issues/507) |
| Ollama | `eval_count` / `eval_duration` usage stats | no | — | [#508](https://github.com/roryford/BaseChatKit/issues/508) |
| Ollama | NDJSON mid-line byte split | no | — | [#509](https://github.com/roryford/BaseChatKit/issues/509) |
| Ollama | `/api/generate` legacy endpoint shape | no | — | [#510](https://github.com/roryford/BaseChatKit/issues/510) |
| Ollama | SSE stream limits (size / event rate) | no | — | [#511](https://github.com/roryford/BaseChatKit/issues/511) |
| Ollama | `Retry-After` header non-numeric variants | partial[^1] | `OllamaBackendTests.swift:230` (`rateLimitError_429`) | [#512](https://github.com/roryford/BaseChatKit/issues/512) |
| Ollama | 404 / 500 / 429 error paths | yes | `OllamaBackendTests.swift:189` / `:210` / `:230` | — |
| Ollama | system prompt in request body | yes | `OllamaBackendTests.swift:125` (`streaming_withSystemPrompt_includesInMessages`) | — |
| Ollama | conversation history serialisation | yes | `OllamaBackendTests.swift:286` (`conversationHistory_usedInMessages`) | — |
| Ollama | malformed NDJSON line handling | yes | `OllamaBackendTests.swift:168` (`streaming_malformedLine_skipped`) | — |

[^1]: Only `Retry-After: "0"` is fixtured; RFC 7231 HTTP-date form and non-trivial integer seconds are not.

### MLX

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| MLX | qwen3 thinking markers | yes | `MLXBackendThinkingTests.swift:59` (`test_thinkingTokensEmittedSeparatelyFromVisibleTokens`) | — |
| MLX | deepseek-r1 thinking markers | partial[^2] | `MLXBackendThinkingTests.swift:59` | — |
| MLX | custom / gpt-oss / gemma4 markers | no | — | [#513](https://github.com/roryford/BaseChatKit/issues/513) |
| MLX | `maxThinkingTokens` cap | no | — | [#514](https://github.com/roryford/BaseChatKit/issues/514) |
| MLX | `maxOutputTokens` with thinking active | yes | `MLXBackendThinkingTests.swift:123` (`test_outputTokenCount_doesNotIncludeThinkingTokens`) | — |
| MLX | no thinking events when markers nil | yes | `MLXBackendThinkingTests.swift:166` (`test_noThinkingEvents_whenMarkersNotSet`) | — |
| MLX | token yield happy path | yes | `MLXBackendGenerationTests.swift:38` (`test_generate_yieldsInjectedTokens`) | — |
| MLX | cancellation via stream termination | yes | `MLXBackendGenerationTests.swift:95` (`test_generate_cancellation`) | — |
| MLX | generate-error propagation | yes | `MLXBackendGenerationTests.swift:141` (`test_generate_generateThrows_propagatesError`) | — |
| MLX | stop_reason variants (`.maxTokens` / EOS / cancel) | no | — | [#515](https://github.com/roryford/BaseChatKit/issues/515) |
| MLX | chat-template detection (missing `tokenizer_config.json`) | no | — | [#516](https://github.com/roryford/BaseChatKit/issues/516) |
| MLX | tool-call deltas (`<tool_call>` tags) | no | — | [#517](https://github.com/roryford/BaseChatKit/issues/517) |
| MLX | `capabilities` surface | yes | `MLXBackendTests.swift:28`-`:42` | — |

[^2]: DeepSeek-R1 uses the same `<think>/</think>` tags as Qwen3, so the qwen3 fixture effectively covers the token-shape. No fixture distinguishes the two at the template-detection layer.

### Llama

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| Llama | init / capabilities / context size | yes | `LlamaBackendTests.swift:32`-`:54` | — |
| Llama | loadModel invalid path | yes | `LlamaBackendTests.swift:58` (`test_loadModel_invalidPath_throws`) | — |
| Llama | loadModel empty GGUF | yes | `LlamaBackendTests.swift:78` (`test_loadModel_emptyFile_throws`) | — |
| Llama | plan-clamp honoured | yes | `LlamaBackendTests.swift:389` (`test_loadModel_fromPlan_clampRespected...`) | — |
| Llama | concurrent `stopGeneration` thread-safety | yes | `LlamaBackendTests.swift:229` | — |
| Llama | stop-then-regenerate (KV cache clear) | yes | `LlamaBackendTests.swift:257` (`...regression390`) | — |
| Llama | GGUF chat-template variants (ChatML / Llama3 / Gemma / Gemma4 / Mistral) | no | — | [#518](https://github.com/roryford/BaseChatKit/issues/518) |
| Llama | EOS token variants (`</s>` / `<|eot_id|>` / multi-EOG Gemma) | no | — | [#519](https://github.com/roryford/BaseChatKit/issues/519) |
| Llama | `n_batch` boundary (N, N+1, contextSize±1) | no | — | [#520](https://github.com/roryford/BaseChatKit/issues/520) |
| Llama | `llama_decode` error paths (prompt / generation) | no | — | [#521](https://github.com/roryford/BaseChatKit/issues/521) |
| Llama | `stopGeneration` fired mid-`llama_decode` | no | — | [#522](https://github.com/roryford/BaseChatKit/issues/522) |
| Llama | tokenizer heuristic fallback | yes | `LlamaBackendTests.swift:438`-`:459` | — |
| Llama | `countTokens` without model throws | yes | `LlamaBackendTests.swift:468` | — |
| Llama | memory-pressure auto-stop | yes | `LlamaBackendMemoryPressureTests.swift` (full file) | — |
| Llama | Llama-serialized load characterisation | yes | `LlamaBackendLoadSerializationCharacterizationTests.swift` (full file) | — |

### Foundation

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| Foundation | init + capabilities | yes | `FoundationBackendUnitTests.swift:132` (`test_capabilities_hasCorrectValues`) | — |
| Foundation | generate before load throws | yes | `FoundationBackendUnitTests.swift:44` | — |
| Foundation | unload clears state / idempotent | yes | `FoundationBackendUnitTests.swift:64` / `:76` | — |
| Foundation | resetConversation preserves isModelLoaded | yes | `FoundationBackendUnitTests.swift:94` / `:105` | — |
| Foundation | `isAvailable` is readable | yes | `FoundationBackendUnitTests.swift:122` | — |
| Foundation | probe session not retained as active | yes | `FoundationBackendUnitTests.swift:183` (hardware-gated) | — |
| Foundation | stop resets session | yes | `FoundationBackendUnitTests.swift:213` (hardware-gated) | — |
| Foundation | `GenerationOptions.topP/topK/seed/repeatPenalty` passthrough | no | — | [#523](https://github.com/roryford/BaseChatKit/issues/523) |
| Foundation | `SystemLanguageModel.Availability` variant handling | no | — | [#524](https://github.com/roryford/BaseChatKit/issues/524) |
| Foundation | cancellation timing mid-partial | no | — | [#525](https://github.com/roryford/BaseChatKit/issues/525) |
| Foundation | structured content-part types (non-monotonic diff) | no | — | [#526](https://github.com/roryford/BaseChatKit/issues/526) |
| Foundation | temperature passthrough | partial[^3] | `FoundationBackendUnitTests.swift:148` | — |

[^3]: Capability test asserts `.temperature` is in `supportedParameters` but no fixture drives a non-default value end-to-end.

### Claude

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| Claude | `text_delta` token extraction | yes | `SSEPayloadReplayTests.swift:45` (`test_claude_realStreamingResponse_extractsTokens`) | — |
| Claude | `message_start` prompt-token usage | yes | `SSEPayloadReplayTests.swift:74` | — |
| Claude | `message_delta` completion-token usage | yes | `SSEPayloadReplayTests.swift:84` | — |
| Claude | usage accumulation across events | yes | `SSEPayloadReplayTests.swift:125` (`test_claude_usageAccumulation_acrossEvents`) | — |
| Claude | `message_stop` isStreamEnd | yes | `SSEPayloadReplayTests.swift:91` | — |
| Claude | SSE `error` event extraction (`overloaded_error`) | yes | `SSEPayloadReplayTests.swift:101` (`test_claude_errorEvent_extractsError`) | — |
| Claude | 401/403 authentication failure | yes | `ClaudeBackendTests.swift:41` (`test_loadModel_withoutAPIKey_throws`) | — |
| Claude | conversation history in request body | yes | `ClaudeBackendTests.swift:141` | — |
| Claude | keychain-backed configure path | yes | `ClaudeBackendTests.swift:238` | — |
| Claude | stopGeneration mid-stream | yes | `ClaudeBackendTests.swift:198` | — |
| Claude | `thinking` / `thinking_delta` content blocks | no | — | [#527](https://github.com/roryford/BaseChatKit/issues/527) |
| Claude | `tool_use` streaming (`input_json_delta`) | no | — | [#528](https://github.com/roryford/BaseChatKit/issues/528) |
| Claude | `citations_delta` handling | no | — | [#529](https://github.com/roryford/BaseChatKit/issues/529) |
| Claude | `stop_reason` variants (`refusal` / `max_tokens` / `stop_sequence`) | partial[^4] | `SSEPayloadReplayTests.swift:57` | [#530](https://github.com/roryford/BaseChatKit/issues/530) |
| Claude | rate-limit error body shape + `anthropic-ratelimit-*` headers | partial[^5] | `ClaudeBackendTests.swift` (no body, only status) | [#531](https://github.com/roryford/BaseChatKit/issues/531) |
| Claude | interleaved content blocks (text + tool_use + thinking) | no | — | [#532](https://github.com/roryford/BaseChatKit/issues/532) |
| Claude | GGUF chat-template variants | n/a | — | — |

[^4]: Only `stop_reason: end_turn` is fixtured (implicitly, via the happy-path payload). `refusal`, `max_tokens`, `stop_sequence`, and `tool_use` are never driven.
[^5]: 429 is driven with empty body and `Retry-After: "0"` only. Structured Anthropic error body and the `anthropic-ratelimit-tokens-reset` header are not exercised.

### Summary

26 gap issues opened (#507–#532): 6 Ollama, 5 MLX, 5 Llama, 4 Foundation, 6 Claude. Each row above with a `no` or `partial` verdict links to the tracking issue. Re-run this audit whenever a new protocol field lands, or when a backend source file's public surface changes meaningfully.

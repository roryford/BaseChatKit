# Plan — `BaseChatServer` (#744)

OpenAI-compatible HTTP server target that exposes any `BaseChatInference.InferenceBackend` over `/v1/chat/completions`. Lets users point Cursor, Continue, and any OpenAI-SDK client at a local Mac running BaseChatKit.

This is a **plan document**, not implementation. It records the decisions taken before code lands so reviewers can argue with the design, not the diff.

## Status

- Tracking issue: #744
- Branch: `feat/744-server-plan`
- Target release: `0.13.0` (headline feature)
- Greenfield work — no prior server code in the repo (`grep -r "Hummingbird\|Vapor\|NIOHTTP" Sources/` returns nothing).

## What we are building

A new opt-in SwiftPM target `BaseChatServer` (executable) plus `BaseChatServerCore` (library, where the routing lives). Together they implement:

- `POST /v1/chat/completions` — streaming (SSE) and non-streaming JSON. Tools, tool_choice, temperature, top_p, max_tokens, seed, stream supported.
- `GET /v1/models` — lists the single loaded model.
- `GET /health/live` and `GET /health/ready` — process liveness vs model-readiness.
- Bearer-token auth (`ApiKeyMiddleware`), conservative CORS, request-cancellation on client disconnect.
- CLI entry point with `--port`, `--bind`, `--api-key-file`, `--parallel`, `--backend mlx|llama|foundation`, `--model <id>`.

Everything inference-shaped (protocols, `GenerationEvent`, cancellation, `BackendRegistrar`) already exists and is reused as-is.

## Non-goals (v1)

Tracked separately on the v2 umbrella issue:

- `/v1/embeddings` — depends on a real `EmbeddingBackend` (#684 was closed without one shipping).
- `/v1/completions` (legacy non-chat).
- `/metrics` Prometheus exporter — structured `Log.*` only in v1.
- Multi-model swap on the request `model:` field — single backend / single model per process in v1.
- Cloud / Ollama backend pass-through (would proxy OpenAI to OpenAI; ship-ready but pointless as a v1 headline).
- `response_format: json_schema` cross-backend — depends on #108 `StructuredOutputStrategy`.
- `n > 1`, `logprobs`, `logit_bias`, `frequency_penalty`, `presence_penalty` — return `400 invalid_request_error` rather than silently ignoring.
- Pre-built binary distribution / Homebrew formula.
- Multi-tenant / per-key quotas / rate limiting beyond the parallel semaphore.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Module shape: library `BaseChatServerCore` + thin executable `BaseChatServer`.** | SwiftLM's 3,068-line `Server.swift` (with documented type-checker timeouts) is a warning. Library form lets routes be unit-tested via Hummingbird's `Application.test()` against `MockInferenceBackend` from `BaseChatTestSupport` — no socket, no flake. |
| 2 | **HTTP framework: Hummingbird 2.x.** | Apache 2.0, NIO-native, Swift-async-first, no Vapor ORM/templating bulk. No realistic alternative — using NIOHTTP1 directly would reinvent routing. |
| 3 | **CLI: `swift-argument-parser`.** | Apple-stack standard. Keeps CLI surface readable next to `bck-tools` / `fuzz-chat`. |
| 4 | **New SPM trait `Server` (opt-in, not default).** | Default dependency graph stays Hummingbird-free. Mirrors the `Fuzz` / `MCPBuiltinCatalog` precedent — heavy/optional deps live behind traits. |
| 5 | **v1 backends: `mlx`, `llama`, `foundation` only.** | `cloud` and `ollama` would proxy OpenAI shape to OpenAI shape — the value is local backends. Cloud pass-through is on the v2 umbrella. |
| 6 | **Single backend, single loaded model per process.** | Local backends serialize through one Metal context anyway. `/v1/models` returns the one. Multi-model swap is a v2 feature with real complexity (LRU eviction, memory budget). |
| 7 | **Tool calling is pass-through; orchestrator disabled.** | OpenAI clients dispatch tools themselves. Server emits `tool_calls` and stops. `ToolCallLoopOrchestrator` is for in-app agent loops, not the wire protocol. |
| 8 | **Finish reason derived in the server, not added to `GenerationEvent`.** | Avoids churning the inference protocol for one consumer. Mapping: clean exit → `"stop"`; any tool-call event → `"tool_calls"`; `.toolLoopLimitReached` or max-tokens → `"length"`; error → `"error"` (custom; OpenAI-SDK clients tolerate). |
| 9 | **Usage estimation for local backends via `TokenizerProvider`.** | Cloud backends populate `.usage(prompt:completion:)` from the wire; local backends don't. Estimating from the tokenizer is honest enough — better than omitting the field, which breaks OpenAI client billing/observability paths. Document the estimation source in the response. |
| 10 | **Drop thinking blocks from server output for v1.** | OpenAI shape has no home for them; clients won't render them. Add `?include=thinking` extension only if a real consumer asks. |
| 11 | **Default bind `127.0.0.1`.** | Binding `0.0.0.0` by default is a footgun on machines that move between networks. `--bind 0.0.0.0` must be explicit. |
| 12 | **API key sourced from `--api-key-file <path>`, not `--api-key <value>`.** | Process-table leaks via `ps` are real. `--api-key` is accepted with a deprecation note (dev-only). |
| 13 | **Default `--parallel 1`.** | Local backends serialize through one Metal context. >1 would queue inside `MLXBackend` anyway. The `AsyncSemaphore` is structural for future cloud/Ollama use. |
| 14 | **Unsupported OpenAI fields: 400 `invalid_request_error` with the field name.** | Silent ignore is the worst possible behavior — clients spend hours tracing "why doesn't `seed` work" when the server quietly dropped it. Loud failure beats quiet drift. |
| 15 | **Two health endpoints: `/health/live` and `/health/ready`.** | Single `/health` is ambiguous for Kubernetes / launchd / `pgrep` style supervisors. Liveness vs readiness is a 5-LOC distinction with real value. |
| 16 | **Hand-roll narrow Codable models for `ChatCompletionRequest` / `Chunk` / `Response`.** | No shippable Swift OpenAI SDK exists that would fit. The surface we use is small (~150 LOC). `OpenAIToolEncoding` (outbound) uses `[String: Any]` and isn't reusable verbatim — extracting a shared module is a refactor we'd regret in v1. Re-converge in v2 if duplication hurts. |
| 17 | **Use `SSEStreamLimits` from `BaseChatInference` for response-side budget caps.** | Same defensive limits the parser enforces inbound apply outbound. One bad request shouldn't stream 50MB. |

## Module structure

```
Sources/
  BaseChatServerCore/          # library — routes, models, middleware, no socket
    Models/
      ChatCompletion+Request.swift
      ChatCompletion+Response.swift
      ChatCompletion+Chunk.swift
      OpenAIError.swift           # invalid_request_error / authentication_error / etc.
    Routes/
      ChatCompletionsRoute.swift  # POST /v1/chat/completions (streaming + non-streaming)
      ModelsRoute.swift           # GET  /v1/models
      HealthRoute.swift           # GET  /health/live, /health/ready
    Middleware/
      ApiKeyMiddleware.swift
      CORSMiddleware.swift
    Streaming/
      SSEEncoder.swift            # data: …\n\n framer + [DONE] sentinel
      EventMapper.swift           # GenerationEvent → ChatCompletionChunk
      FinishReasonDeriver.swift   # stream-end → "stop" | "tool_calls" | "length"
    Concurrency/
      AsyncSemaphore.swift        # ~30 LOC actor (lifted shape from SwiftLM)
    Server.swift                  # buildApplication(config:) -> Hummingbird.Application

  BaseChatServer/                # executable
    main.swift                   # @main, parses CLI, calls buildApplication, .run()
    CLI.swift                    # ArgumentParser surface

Tests/
  BaseChatServerTests/
    Routes/
      ChatCompletionsRouteTests.swift
      ChatCompletionsStreamingTests.swift
      ChatCompletionsToolsTests.swift
      ModelsRouteTests.swift
      HealthRouteTests.swift
    Middleware/
      ApiKeyMiddlewareTests.swift
      CORSMiddlewareTests.swift
    Streaming/
      SSEEncoderTests.swift
      EventMapperTests.swift
      FinishReasonDeriverTests.swift
    Concurrency/
      AsyncSemaphoreTests.swift
    Integration/
      ClientDisconnectCancellationTests.swift   # disconnect mid-stream → stopGeneration() fires
      EndToEndOpenAIClientTests.swift            # real openai-python via subprocess (gated)
```

`BaseChatServerCore` depends on: `BaseChatInference`, `BaseChatBackends`, `BaseChatTestSupport` (test only), `Hummingbird`.
`BaseChatServer` depends on: `BaseChatServerCore`, `swift-argument-parser`.

The split keeps `BaseChatServerCore` testable without sockets, and the executable target stays a thin wrapper — same pattern as the `bck-tools`/`fuzz-chat` precedents but with a real library underneath because the surface justifies it.

## Wire mapping

`GenerationEvent` → OpenAI SSE chunks:

| `GenerationEvent` case | OpenAI chunk |
|---|---|
| `.token(s)` | `choices[0].delta.content = s` |
| `.toolCallStart(id, name)` | `choices[0].delta.tool_calls[idx] = {id, type: "function", function: {name}}` |
| `.toolCallArgumentsDelta(id, frag)` | `choices[0].delta.tool_calls[idx].function.arguments = frag` |
| `.toolCall(call)` | (assemble fallback if no streamed deltas seen for id) |
| `.usage(p, c)` | `usage = {prompt_tokens: p, completion_tokens: c, total_tokens: p+c}` on final chunk if `stream_options.include_usage = true` |
| `.thinkingToken(_)` / `.thinkingComplete` / `.thinkingSignature(_)` | dropped (v1) |
| `.toolResult(_)` | dropped (server is pass-through; client owns dispatch) |
| `.kvCacheReuse(_)` / `.diagnosticThrottle(_)` | dropped (internal signals) |
| `.toolLoopLimitReached(_)` | derive `finish_reason: "length"` |
| stream end clean | derive `finish_reason: "stop"` (or `"tool_calls"` if any tool-call event seen) |
| stream error | emit `data: {"error": {…}}\n\n` then close; OpenAI clients handle this |

## Cancellation

The framework already has the contract: `stopGeneration()` cancels the in-flight stream and resets backend state, and structured concurrency propagates from Hummingbird's per-request task. When the client disconnects mid-stream:

1. Hummingbird cancels the response task.
2. The route handler's `for try await event in stream.events` throws `CancellationError`.
3. `defer { backend.stopGeneration() }` fires.
4. `MLXBackend.stopGeneration()` (or whichever) tears down state and is ready for the next request.

This needs an explicit acceptance test (`ClientDisconnectCancellationTests`) — it's an easy regression and not visible until the server is heavily used.

## Test strategy

- **Unit (route-level):** Hummingbird `Application.test()` + `MockInferenceBackend`. Cover all OpenAI shape edge cases — empty messages, malformed tools, unsupported fields → 400, auth header missing → 401, etc. No sockets.
- **Streaming:** `EventMapperTests` drive a synthetic `AsyncStream<GenerationEvent>` through the encoder and assert SSE bytes. Includes the parallel-tool-call case (multiple `index` lanes interleaved) since that's the part most likely to break under real load.
- **Cancellation:** `ClientDisconnectCancellationTests` cancels the test client mid-response and asserts `stopGeneration()` was invoked on the mock.
- **Sabotage:** Per CLAUDE.md, every assertion gets a temporary code break verifying the test fails before commit.
- **End-to-end (gated):** `EndToEndOpenAIClientTests` shells out to `python -c "from openai import OpenAI; …"` against a real bound port, gated on `RUN_SERVER_E2E=1` and macOS. Confirms wire compatibility against the canonical client. Not in default CI.
- **CI gate:** `BaseChatServerTests --disable-default-traits` runs in CI alongside the existing suite. No hardware required (mock backend only).

## Security posture

- Default bind `127.0.0.1`.
- `--bind 0.0.0.0` requires either `--api-key-file` to be set OR `--unsafe-no-auth` to be passed explicitly. Refuse to start otherwise.
- API key compared with `constantTimeEquals` to avoid timing oracles.
- CORS disabled by default. `--cors-origin <origin>` accepts a single origin; `--unsafe-cors-any` is required to allow `*`.
- Request body size capped at 1 MiB (configurable via `--max-request-bytes`). Defends against accidental large pastes.
- Response stream capped using `SSEStreamLimits` defaults (50 MiB total, 5000 events/sec).
- Errors funneled through `OpenAIError` enum with explicit code mapping — never leak Swift type names or stack traces.
- No file paths, model names, or backend identifiers logged at default level — only at `--log-level debug`.
- Dependency review: Hummingbird and ArgumentParser are both Apache 2.0, MIT-compatible. No new transitive deps that haven't been vetted.

## CI

Add to the pre-push checklist and CI matrix:

```bash
swift test --filter BaseChatServerCoreTests --disable-default-traits --traits Server
```

The `Server` trait is required because the test target depends on Hummingbird. If the trait is off, the target compiles to zero files and the filter no-ops — same pattern as `Ollama` / `Fuzz` today.

CI line in `.github/workflows/*.yml` mirrors the existing `swift test --filter` invocations. ~30 seconds of runtime added (mostly link).

## Rollout

1. **PR 1 — this plan doc.** No code. Three persona reviews land here.
2. **PR 2 — skeleton.** `Package.swift` trait + targets, empty `BaseChatServerCore`, empty executable, `BaseChatServerCoreTests` placeholder. Confirms the build graph is clean before any feature work. ~150 LOC.
3. **PR 3 — non-streaming `/v1/chat/completions` + `/v1/models` + `/health/*` + auth/CORS middleware.** Mock backend tests only. ~600 LOC.
4. **PR 4 — streaming SSE + `EventMapper` + cancellation.** Adds `ClientDisconnectCancellationTests`. ~400 LOC.
5. **PR 5 — tool calling pass-through.** OpenAI client `tools=[…]` flow end-to-end against the mock. ~200 LOC.
6. **PR 6 — CLI surface + executable target + README section.** Manual smoke against `mlx-community/Llama-3.2-3B-Instruct-4bit` and a real `openai` Python client. ~150 LOC. Lands the user-visible surface.
7. **Release 0.13.0.** Highlight section in CHANGELOG with a 6–8 line code snippet showing `swift run BaseChatServer --backend mlx --model …` → `from openai import OpenAI; client.chat.completions.create(...)`.

Each PR is independently reviewable, CI-green at every step, and revertable. PR 6 is the one that ships the feature; PRs 2–5 are infrastructure that's safe to land incrementally because nothing references it from outside the new module.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Hummingbird API churn between minor versions | Pin to `2.x.y` exact in `Package.swift`; bump deliberately. |
| Local-backend usage estimates diverge from cloud actuals enough to break observability tools | Document the source explicitly (`x-basechat-usage-source: tokenizer-estimate` header in non-streaming responses); revisit in v2 with a real counting hook. |
| Client disconnect doesn't propagate cancellation in some Hummingbird configuration | Explicit acceptance test on day one. Easy to detect, painful in production. |
| Parallel tool-call events arrive out of order across `index` lanes and break OpenAI's strict-index expectation | `EventMapperTests` covers interleaved lanes; `ToolCallLoopOrchestrator` already sorts by batch index for KV-prefix stability (#783), so the upstream ordering is correct. |
| OpenAI SDK clients reject responses with our custom `finish_reason: "error"` | Test against the real `openai` Python client in `EndToEndOpenAIClientTests`. If the SDK rejects, fall back to `"stop"` + an `error` field on the chunk. |
| Server target pulls Hummingbird into the default graph by accident | Trait gate enforced by `swift package resolve` failing if the default-trait build pulls server deps. CI `--disable-default-traits` invocation confirms. |
| Type-checker timeouts (the SwiftLM cautionary tale) | Module split (`BaseChatServerCore` vs `BaseChatServer`) keeps any one file small. Hard rule: no file over 400 LOC. |

## Open questions for review

1. Is `0.13.0` the right release window, or should this slip to `0.14.0` to keep `0.13.0` focused on closing out the tool-calling track (#753 PR-C + #444)?
2. Should `BaseChatServerCore` ship public-API for embedding it in another executable (e.g., a Mac menubar app that wants the same routes), or stay `package`-visible?
3. The `--parallel` flag is structural in v1 (default 1, semaphore mostly idle). Drop it from the v1 CLI to reduce surface, or keep it documented as future-facing?
4. Should `/v1/models` reflect *available* backends/models on disk (richer for clients) or only the *loaded* one (simpler, honest)?

These are the four genuine forks where I'd like reviewer disagreement, in addition to anything else they spot.

# Security Model

What BaseChatKit protects against out of the box, what remains your responsibility, and how to tune the framework for stricter threat models.

## Overview

BaseChatKit ships with defense-in-depth for the common LLM-chat threats: stolen API keys, MITM on cloud calls, crafted filenames from remote metadata, and prompt template leakage. This page documents what's protected *today on main*, what's your responsibility, and how to raise the floor for stricter environments.

The framework targets integrators building consumer or prosumer Apple-platform chat apps. It is not hardened for kiosk, MDM-managed, or regulated deployments without additional controls on top.

## Transport security

Cloud backends (Claude, OpenAI, and OpenAI-compatible) route through a shared `URLSession` guarded by a certificate-pinning delegate. Pinning runs at the **public-key (SPKI) level** and checks every certificate in the presented chain, not just the leaf — so a routine leaf rotation does not trigger a lockout.

The default pin set covers the two hosts BCK makes production calls to:

| Host | Pinned SPKI |
|------|-------------|
| `api.anthropic.com` | Google Trust Services WE1 (intermediate) and GTS Root R4 (backup) |
| `api.openai.com`    | Google Trust Services WE1 (intermediate) and GTS Root R4 (backup) |

**Fail-closed behaviour.** These two hosts are classified as *required pinned hosts*. If the pin set is empty or the chain does not match, the authentication challenge is cancelled — there is no fallback to default trust. This is intentional: a misconfiguration on a known production host should stop the request, not silently downgrade.

**Custom hosts.** Any other host (your own OpenAI-compatible endpoint, a self-hosted gateway, Ollama on a remote machine) falls through to the platform's default trust evaluation *unless* you add pins for it:

```swift
import BaseChatBackends

PinnedSessionDelegate.pinnedHosts["chat.mycompany.com"] = [
    "base64-spki-sha256-pin-1=",
    "base64-spki-sha256-pin-2=" // backup for rotation
]
```

**Localhost is exempt.** `localhost`, `127.0.0.1`, and `::1` always bypass pinning so local Ollama or LM Studio development servers keep working without ceremony.

**Pin rotation.** When a provider rotates their chain, add new pins *before* removing the old ones, ship the update, and only retire the stale pin once no clients are still presenting the previous chain. Always carry at least one backup pin per host to survive an emergency rotation.

## Credentials and API keys

API keys are stored in the system Keychain via ``KeychainService``, keyed by each endpoint's UUID. Storage attributes:

- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — keys are unavailable when the device is locked and **do not** sync via iCloud Keychain.
- Service name comes from `BaseChatConfiguration.shared.keychainServiceName` so multiple apps sharing a team ID stay isolated.

**Just-in-time retrieval.** Backends read the key from Keychain per request rather than caching it as a stored property, which limits the window where a memory-dump attacker sees the plaintext.

**Masked logging.** `KeychainService.masked(_:)` returns a truncated form (`"sk-a...xyz"`) suitable for diagnostics. Never log the raw key.

On main today, `store` and `delete` return `Bool`. Failures are surfaced to the caller but are not thrown. Treat a `false` return as a terminal failure for that endpoint — do not retry silently, because repeated Keychain errors usually indicate a provisioning, entitlement, or system policy problem.

## At-rest data

Chat sessions and messages live in a SwiftData store under Application Support. The store itself inherits **whatever file-protection class the platform applies by default**: on iOS that is effectively `CompleteUntilFirstUserAuthentication`, on macOS it relies on FileVault.

SwiftData has no built-in payload encryption beyond file protection. If your threat model requires strict data-at-rest protection (for example, a note-taking app that must remain sealed while locked even after first unlock), layer your own encryption on top or configure a stricter file-protection class on the container URL at startup.

## Custom endpoints

``APIEndpoint/isValid`` performs a structural check on user-entered base URLs: it parses the URL, requires a scheme and host, and **rejects non-HTTPS schemes for anything that is not localhost**. Localhost (`localhost`, `127.0.0.1`, `::1`, `[::1]`) is allowed to use `http://` so developers can target Ollama or LM Studio without certificates.

What this check does **not** do today:

- It does not enumerate RFC 1918 / link-local / IPv6 ULA ranges. An entered hostname that resolves to `10.0.0.0/8` or `169.254.169.254` is not blocked at the model layer.
- It does not defeat DNS rebinding — the hostname is resolved by the underlying `URLSession` at request time, not validated structurally here.

If your host environment allows untrusted users to configure endpoints (for example, a shared Mac or an MDM-provisioned iPad), add a validation layer above `APIEndpoint` that resolves the host and rejects private address space before you persist the record. A stricter validator is on the roadmap (see the "Roadmap" section below).

## Prompt template hardening

GGUF models do not apply their own chat templates, so BCK's ``PromptTemplate`` wraps messages in the format the model was trained on (ChatML, Llama 3, Mistral, Alpaca, Gemma, Phi). Before each user message is interpolated, the template strips the **special tokens specific to that format** (`<|im_start|>`, `[INST]`, `<|eot_id|>`, etc.). This prevents a user pasting a fake `<|im_start|>system` turn and reshaping the conversation.

This is a narrow defense against *structural* injection, not semantic jailbreaks. See "Prompt injection" below.

## Downloads

Model downloads from HuggingFace stage into a per-download directory before being moved into `modelsDirectory`. Both the staging path and the final placement are checked:

- Each file in a multi-file snapshot must resolve to a path whose `.standardized.path` has the staging directory as a prefix. A crafted relative path (e.g. from manipulated `siblings` metadata containing `../`) is rejected with ``HuggingFaceError``.
- The final move into `modelsDirectory` applies the same prefix check against the models directory. A `fileName` that escapes is rejected before the move.

On main, those checks live in the download placement path. A dedicated filename validator and orphan-temp-sweep are tracked for a future release (see "Roadmap").

## Observability

Calls to `Log.*` use `privacy: .private` for credentials, prompts, and user content. `privacy: .public` is reserved for stable identifiers (host names, model file names that the app itself chose, task phases). If you re-use the logger in your own integration code, mirror the same annotation discipline — Console redaction is lost the moment a single `%{public}s` leaks a secret.

## Prompt injection — explicit threat-model disclaimer

**Prompt injection is inherent to the LLM-chat domain and BaseChatKit does not solve it.**

- The framework does **not** sanitize the boundary between system prompt and user content at the semantic level. Only the structural special-token strip described above.
- System prompts are **not a security boundary**. Any user or any document you paste into the context can override them with enough determination.
- Tool calls, retrieval-augmented content, and pasted web pages are untrusted input from the model's perspective. Treat their influence on the conversation the same way you would treat a cross-origin iframe in a browser.

Recommended mitigations, in roughly increasing cost:

1. Use **structured message formats** where the provider exposes them (OpenAI/Anthropic `tool_use` payloads, response JSON schemas) instead of stuffing instructions into plain prose.
2. Add a **content-filtering layer** before the model sees the text when your app ingests user-uploaded documents.
3. Keep **capability scopes small** — a tool that can only read today's calendar is much cheaper to expose than one that can send email.

## Out of scope

The framework does not attempt to protect against:

- DNS rebinding
- User-installed MITM certificates (corporate proxies, jailbreak tweaks)
- Compromised host OS, jailbroken or rooted devices
- Side-channel attacks on shared Mac user sessions
- Supply-chain attacks on pre-built model weights — GGUF SHA manifest verification is **roadmap**, not current
- Physical-access and social-engineering attacks (these are also excluded from our disclosure scope in [SECURITY.md](https://github.com/roryford/BaseChatKit/blob/main/.github/SECURITY.md))

## Roadmap

Security work that is in progress but not yet on `main`:

- Private/link-local range rejection inside ``APIEndpoint/isValid`` (SSRF hardening for user-entered base URLs)
- SSE stream size and rate caps to defeat hostile-server resource exhaustion
- Upstream error-body sanitization before surfacing to the UI
- Throwing Keychain APIs (`store` / `delete`)
- Dedicated ``DownloadableModel`` filename validator plus an orphan temp-directory sweep
- ReDoS-bounded quantization-tag regex
- GGUF SHA manifest verification

Pin this page in your security review checklist — the "Roadmap" section shrinks as those ship.

## Reporting a vulnerability

Report suspected vulnerabilities through [GitHub Security Advisories](https://github.com/roryford/BaseChatKit/security/advisories/new). Do not open public issues for security reports. Full policy and response timelines: [SECURITY.md](https://github.com/roryford/BaseChatKit/blob/main/.github/SECURITY.md).

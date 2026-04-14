# Security Model

What BaseChatKit protects against out of the box, what remains your responsibility, and how to tune the framework for stricter threat models.

## Overview

BaseChatKit ships defense-in-depth for the common LLM-chat threats: stolen API keys, MITM on cloud calls, SSRF via user-entered endpoints, crafted filenames from remote metadata, and hostile upstream error bodies. This page documents what's protected *today on main*. The framework targets integrators building consumer or prosumer Apple-platform chat apps; it is not hardened for kiosk, MDM-managed, or regulated deployments without additional controls on top.

## Transport security

**Protected:** MITM on Claude and OpenAI traffic, including a rogue CA silently installed on the device.

Cloud backends route through a shared `URLSession` guarded by a certificate-pinning delegate. Pinning runs at the **SPKI level** and checks every certificate in the presented chain, so routine leaf rotation does not trigger a lockout.

The default pin set, populated by `PinnedSessionDelegate.loadDefaultPins()`, pins Google Trust Services WE1 (intermediate) plus GTS Root R4 (backup) on both `api.anthropic.com` and `api.openai.com`. Both are classified as *required pinned hosts*: if the pin set is empty or no certificate in the chain matches, the challenge is cancelled — no fallback to default trust.

**Custom hosts** (your own OpenAI-compatible endpoint, a self-hosted gateway, remote Ollama) fall through to the platform's default trust evaluation *unless* you add pins:

```swift
import BaseChatBackends

PinnedSessionDelegate.pinnedHosts["chat.mycompany.com"] = [
    "base64-spki-sha256-pin-1=",
    "base64-spki-sha256-pin-2=" // backup for rotation
]
```

`localhost`, `127.0.0.1`, and `::1` always bypass pinning for local development.

**Pin rotation.** Add new pins *before* removing the old ones, ship the update, and retire the stale pin only once no clients are still presenting the previous chain. Always carry at least one backup pin per host.

## Custom endpoints (SSRF)

**Protected:** a user-pasted base URL that resolves to the LAN or a cloud metadata service (`169.254.169.254`) cannot be persisted.

``APIEndpoint/isValid`` performs a structural check on every user-entered base URL:

- **Scheme** must be `http` or `https`. `file://`, `ftp://`, `data:`, `javascript:` and friends are rejected.
- **HTTPS is required** for non-loopback hosts. Plain `http://` is accepted only for `localhost`, `127.0.0.1`, and `::1`.
- **IP-literal hosts** are classified against blocked ranges. IPv4: `0.0.0.0/8`, RFC 1918 (`10/8`, `172.16/12`, `192.168/16`), `127/8` except `127.0.0.1`, `169.254/16` (link-local, incl. `169.254.169.254` cloud metadata), `224/4` (multicast), `240/4` (reserved). IPv6: `fc00::/7` (unique local), `fe80::/10` (link-local), `::ffff:0:0/96` (IPv4-mapped — would otherwise bypass the IPv4 filter).
- **Trailing-dot FQDNs** (`https://192.168.1.1.`) are canonicalised so they cannot bypass the gate.

What this check does **not** do: it does not resolve DNS names (validation runs synchronously from SwiftUI forms and must stay fast), and it does not defeat **DNS rebinding** — the resolver's answer at request time may differ from any answer observed at validation time. Deployments that need that guarantee should add a request-layer mitigation (reject private IPs returned by `URLSession` host resolution, or pin resolution to a known resolver).

## Credentials and API keys

**Protected:** API keys do not live on disk, never sync to iCloud Keychain, and silent Keychain failures cannot leave the UI thinking a key is saved when it isn't.

Keys are stored in the system Keychain via ``KeychainService``, keyed by each endpoint's UUID. The access class is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — keys are unavailable while the device is locked and **do not** sync via iCloud Keychain. The service name comes from `BaseChatConfiguration.shared.keychainServiceName`, so apps sharing a team ID stay isolated.

`KeychainService.store(key:account:)` and `KeychainService.delete(account:)` **throw** `KeychainError` on failure; `retrieve(account:)` returns `nil` because a missing item is a normal state. `KeychainError.localizedDescription` maps common `OSStatus` codes (locked device, missing entitlement, auth failure) to a user-facing string; `KeychainError.osStatus` exposes the raw code for callers that need to branch on it. Backends read the key per request rather than caching it as a stored property, limiting the window where a memory-dump attacker sees the plaintext. `KeychainService.masked(_:)` returns `"sk-a...xyz"` for diagnostics; never log the raw key.

**Migration note.** `APIEndpoint.setAPIKey(_:)` and `deleteAPIKey()` are `throws`; call sites must be `try endpoint.setAPIKey(key)`. Surfacing the error is load-bearing — swallowing it leaves the user believing their key is saved when the Keychain actually rejected the write.

## At-rest data

**Protected (iOS / iPadOS / tvOS / watchOS):** the SwiftData store is sealed by Data Protection until the user first unlocks the device after reboot.

``ModelContainerFactory/makeContainer(configurations:)`` applies the file-protection class configured via `BaseChatConfiguration.fileProtectionClass` to the store file and its SQLite `-shm` / `-wal` sidecars. The default is `.completeUntilFirstUserAuthentication` — sensitive data is protected at rest, but background tasks (silent pushes, downloads resumed after app termination) still work. Set `.complete` for the strongest sealing (breaks background reads while locked), or `nil` to opt out entirely:

```swift
BaseChatConfiguration.shared = BaseChatConfiguration(
    fileProtectionClass: .complete
)
```

On macOS and Mac Catalyst, file-level protection is a no-op — at-rest protection is handled by FileVault. In-memory stores (tests, previews) skip protection entirely.

## Upstream error sanitisation

**Protected:** a hostile proxy, a misconfigured custom endpoint, or an upstream bug cannot inject HTML, invisible bidi characters, or leaked tokens into the chat UI via an error message.

Before any cloud error body is surfaced through `CloudBackendError.serverError(statusCode:message:)`, `SSECloudBackend.checkStatusCode(_:bytes:)` runs it through `CloudErrorSanitizer.sanitize(_:host:)`. The sanitiser strips control bytes (C0/C1), zero-width joiners, BOMs, and bidirectional overrides; collapses whitespace; rejects HTML-shaped bodies (`<` followed by an ASCII letter — Cloudflare 5xx pages, proxy interstitials) and substitutes `"Server error from <host>"`; redacts messages containing a URL scheme or a JWT prefix (`eyJ`), which almost always means the upstream is echoing a token or callback URL; and truncates to 256 characters with an ellipsis.

Raw bodies are logged via `Log.*` at `privacy: .debug` only — they never appear in production Console output, and never reach the UI unfiltered.

## Model downloads

**Protected:** a malicious HuggingFace manifest (`../../Library/Preferences/…`) cannot write outside the models directory, and a previous-run crash cannot accumulate multi-GB temp files indefinitely.

``DownloadableModel/validate(fileName:)`` runs at the earliest point a filename enters the system (manifest parsing, Hub search results, snapshot downloads) and rejects: empty or `>= 255` characters (POSIX `NAME_MAX`); any backslash (never legitimate on Apple platforms); any control character (C0, DEL, C1 — truncation hazards and invisible `U+0085 NEXT LINE` injection); any `..` or `.` component (classic path traversal); a leading, trailing, or consecutive `/`; more than one `/` (only `<namespace>/<name>` is honoured — `a/b/c` is rejected rather than silently accepting a sub-path write); and any component beginning with `.` (hides the file and collides with `.DS_Store`, `.git`).

Placement into `modelsDirectory` additionally enforces a `.standardized.path` prefix check, so a filename that slips past structural validation still cannot escape the models directory.

**Stale-temp sweep.** `BackgroundDownloadManager.cleanupStaleTempFiles()` runs on launch from `reconnectBackgroundSession()`. It removes regular files in `FileManager.default.temporaryDirectory` that match *all* of: filename prefix `"basechatkit-dl-"`, extension `"download"`, and modification date older than 24 hours. The prefix keeps the sweep from touching files produced by other subsystems; the 24-hour floor keeps it from clobbering an in-flight download that the system's background transfer service hasn't handed back yet.

## Regex ReDoS

**Protected:** a filename crafted to induce catastrophic backtracking cannot freeze the UI.

`DownloadableModel.quantization` extracts the quant tag (`Q4_K_M`, `IQ2_XXS`, `BF16`) with a regex whose trailing `(?:_[A-Z0-9]+)` group is bounded to `{0,5}` repetitions, and the input is clipped to a 128-character prefix before evaluation. Real quant tags cap at two suffix components; the bounded envelope neutralises pathological input.

## Prompt template hardening

**Protected:** a user cannot paste a fake `<|im_start|>system` turn and reshape the conversation.

GGUF models do not apply their own chat templates, so ``PromptTemplate`` wraps messages in the format the model was trained on (ChatML, Llama 3, Mistral, Alpaca, Gemma, Phi). Before each user message is interpolated, the template strips the special tokens specific to that format (`<|im_start|>`, `[INST]`, `<|eot_id|>`, …). Narrow defense against *structural* injection, not semantic jailbreaks.

## Observability

`Log.*` calls use `privacy: .private` for credentials, prompts, and user content; `privacy: .public` is reserved for stable identifiers (host names, chosen file names, task phases, `OSStatus` codes). Mirror the same discipline in your own integration code — Console redaction is lost the moment a single `%{public}s` leaks a secret.

## Prompt injection — explicit disclaimer

**Prompt injection is inherent to the LLM-chat domain and BaseChatKit does not solve it.** The framework does not sanitize the semantic boundary between system prompt and user content; only the structural special-token strip above. System prompts are not a security boundary — any user, or any document pasted into context, can override them with enough determination. Tool calls, retrieved content, and pasted web pages are untrusted input from the model's perspective; treat their influence on the conversation the way you would treat a cross-origin iframe.

Mitigations, in roughly increasing cost: use structured message formats (provider `tool_use` payloads, JSON schemas) rather than stuffing instructions into prose; add a content-filtering layer before user-uploaded documents reach the model; keep capability scopes small — a tool that reads today's calendar is much cheaper to expose than one that sends email.

## Out of scope

The framework does not attempt to protect against DNS rebinding; user-installed MITM certificates (corporate proxies, jailbreak tweaks); a compromised host OS or jailbroken/rooted device; side-channel attacks on shared Mac user sessions; supply-chain attacks on pre-built model weights (GGUF SHA manifest verification is **roadmap**); or physical-access and social-engineering attacks (also excluded from our disclosure scope in [SECURITY.md](https://github.com/roryford/BaseChatKit/blob/main/.github/SECURITY.md)).

## Roadmap

In progress, not yet on `main`: SSE stream size and rate caps (hostile-server DoS); Keychain orphan reaper (prunes items whose owning `APIEndpoint` has been deleted); GGUF SHA manifest verification for downloaded weights.

## Reporting a vulnerability

Report suspected vulnerabilities through [GitHub Security Advisories](https://github.com/roryford/BaseChatKit/security/advisories/new) — do not open public issues. Full policy: [SECURITY.md](https://github.com/roryford/BaseChatKit/blob/main/.github/SECURITY.md).

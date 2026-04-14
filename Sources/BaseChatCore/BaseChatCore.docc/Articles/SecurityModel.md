# Security Model

What BaseChatKit protects against out of the box, what remains your responsibility, and how to tune the framework for stricter threat models.

## Overview

BaseChatKit ships defense-in-depth for the common LLM-chat threats: stolen API keys, MITM on cloud calls, SSRF via user-entered endpoints, crafted filenames from remote metadata, and hostile upstream error bodies. This page documents what's protected *today on main*. The framework targets integrators building consumer or prosumer Apple-platform chat apps; it is not hardened for kiosk, MDM-managed, or regulated deployments without additional controls on top.

## Transport security

**Protected:** MITM on Claude and OpenAI traffic, including a rogue CA silently installed on the device.

Cloud backends route through a shared `URLSession` guarded by a certificate-pinning delegate. Pinning runs at the **SPKI level** and checks every certificate in the presented chain, so routine leaf rotation does not trigger a lockout. The default pin set, populated by `PinnedSessionDelegate.loadDefaultPins()`, pins Google Trust Services WE1 (intermediate) plus GTS Root R4 (backup) on both `api.anthropic.com` and `api.openai.com`. Both are classified as *required pinned hosts*: if the pin set is empty or no certificate in the chain matches, the challenge is cancelled — no fallback to default trust.

**Custom hosts** (your own OpenAI-compatible endpoint, a self-hosted gateway, remote Ollama) fall through to the platform's default trust evaluation *unless* you add pins:

```swift
import BaseChatBackends

PinnedSessionDelegate.pinnedHosts["chat.mycompany.com"] = [
    "base64-spki-sha256-pin-1=",
    "base64-spki-sha256-pin-2=" // backup for rotation
]
```

`localhost`, `127.0.0.1`, and `::1` always bypass pinning for local development. When rotating pins, add the new pin alongside the old one before shipping the update — always carry at least one backup pin per host.

## Custom endpoints (SSRF)

**Protected:** a user-pasted base URL that resolves to the LAN or a cloud metadata service (`169.254.169.254`) cannot be persisted, and the UI can explain *why* an endpoint was rejected instead of a generic "invalid" label.

``APIEndpoint/validate()`` returns `Result<Void, APIEndpointValidationReason>`; surface `reason.errorDescription` (it conforms to `LocalizedError`) and branch on the specific case for diagnostics:

```swift
switch endpoint.validate() {
case .success:
    // persist and use the endpoint
case .failure(let reason):
    settings.errorMessage = reason.errorDescription
    // reason is one of .emptyURL, .malformedURL, .unsupportedScheme(String),
    // .insecureScheme, .privateHost, .linkLocalHost, .ipv6UniqueLocal,
    // .ipv4MappedLoopback, .multicastReserved — use to tailor recovery UI.
}
```

``APIEndpoint/isValid`` is a boolean convenience derived from `validate()` — use it for a simple "ready to save" check. The nine ``APIEndpointValidationReason`` cases map 1:1 to the enforced rules:

- **Scheme** must be `http` or `https` — `file://`, `ftp://`, `data:`, `javascript:` trip `.unsupportedScheme(String)` (associated value carries the offending scheme).
- **HTTPS required** for non-loopback hosts; plain `http://` is accepted only for `localhost`, `127.0.0.1`, and `::1`, otherwise `.insecureScheme`.
- **IP-literal hosts** are bucketed by address class: `.privateHost` for RFC 1918 (`10/8`, `172.16/12`, `192.168/16`); `.linkLocalHost` for IPv4 `169.254/16` (including `169.254.169.254` cloud metadata) and IPv6 `fe80::/10`; `.ipv6UniqueLocal` for `fc00::/7`; `.ipv4MappedLoopback` for `::ffff:0:0/96` (would otherwise bypass the IPv4 filter); `.multicastReserved` for `0.0.0.0/8`, non-`127.0.0.1` encodings in `127/8`, `224/4` multicast, and `240/4` reserved.
- **Trailing-dot FQDNs** (`https://192.168.1.1.`) are canonicalised so they cannot bypass the gate.

What this check does **not** do: it does not resolve DNS names (validation runs synchronously from SwiftUI forms), and it does not defeat **DNS rebinding** — the resolver's answer at request time may differ from any answer observed at validation time. Deployments that need that guarantee should add a request-layer mitigation (reject private IPs returned by `URLSession` host resolution, or pin resolution to a known resolver).

## Credentials and API keys

**Protected:** API keys do not live on disk, never sync to iCloud Keychain, and silent Keychain failures cannot leave the UI thinking a key is saved when it isn't.

Keys are stored in the system Keychain via ``KeychainService``, keyed by each endpoint's UUID. The access class is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — keys are unavailable while the device is locked and **do not** sync via iCloud Keychain. The service name comes from `BaseChatConfiguration.shared.keychainServiceName`, so apps sharing a team ID stay isolated.

`KeychainService.store(key:account:)` and `KeychainService.delete(account:)` **throw** `KeychainError` on failure; `retrieve(account:)` returns `nil` because a missing item is a normal state. `KeychainError.localizedDescription` maps common `OSStatus` codes (locked device, missing entitlement, auth failure) to a user-facing string; `KeychainError.osStatus` exposes the raw code. Backends read the key per request rather than caching it as a stored property, limiting the memory-dump window. `KeychainService.masked(_:)` returns `"sk-a...xyz"` for diagnostics; never log the raw key.

**Migration note.** `APIEndpoint.setAPIKey(_:)` and `deleteAPIKey()` are `throws`; call sites must be `try endpoint.setAPIKey(key)`. Surfacing the error is load-bearing — swallowing it leaves the user believing their key is saved when the Keychain actually rejected the write.

**Orphan reaper.** ``BaseChatBootstrap/reapOrphanedKeychainItems(in:)`` runs once from ``SwiftDataPersistenceProvider``'s initialiser and deletes any Keychain item in the framework's service namespace whose owning ``BaseChatSchemaV3/APIEndpoint`` row no longer exists, via ``KeychainService/sweep(validAccounts:)``. Orphans accumulate when the SwiftData row is removed while the paired Keychain delete silently fails, or when rows are wiped directly through SwiftData without routing through the UI. Individual failures log at `.warning` without halting the sweep. Gated by `BaseChatConfiguration.keychainReaperEnabled` (default `true`) — host apps whose test fixtures populate the shared namespace independently should disable it.

## At-rest data

**Protected (iOS / iPadOS / tvOS / watchOS):** the SwiftData store is sealed by Data Protection until the user first unlocks the device after reboot.

``ModelContainerFactory/makeContainer(configurations:)`` applies the file-protection class configured via `BaseChatConfiguration.fileProtectionClass` to the store file and its SQLite `-shm` / `-wal` sidecars. The default `.completeUntilFirstUserAuthentication` protects data at rest while letting background tasks (silent pushes, resumed downloads) still work. Set `.complete` for the strongest sealing (breaks background reads while locked) or `nil` to opt out:

```swift
BaseChatConfiguration.shared = BaseChatConfiguration(
    fileProtectionClass: .complete
)
```

On macOS and Mac Catalyst, file-level protection is a no-op — at-rest protection is handled by FileVault. In-memory stores (tests, previews) skip protection entirely.

## Upstream error sanitisation

**Protected:** a hostile proxy, a misconfigured custom endpoint, or an upstream bug cannot inject HTML, invisible bidi characters, or leaked tokens into the chat UI via an error message.

Before any cloud error body is surfaced through `CloudBackendError.serverError(statusCode:message:)`, `SSECloudBackend.checkStatusCode(_:bytes:)` runs it through `CloudErrorSanitizer.sanitize(_:host:)`. The sanitiser strips control bytes (C0/C1), zero-width joiners, BOMs, and bidirectional overrides; collapses whitespace; replaces HTML-shaped bodies (Cloudflare 5xx pages, proxy interstitials) with `"Server error from <host>"`; redacts messages containing a URL scheme or JWT prefix (`eyJ`) — almost always an echoed token or callback URL; and truncates to 256 characters. Raw bodies log at `privacy: .debug` only, and never reach the UI unfiltered.

## SSE stream bounds

**Protected:** a hostile upstream (or a compromised proxy) cannot hand the client an unbounded stream that exhausts memory or pins the event loop.

Every SSE stream is consumed through ``SSEStreamParser`` under ``SSEStreamLimits``. The defaults (``SSEStreamLimits/default``) cap a single event payload at **1 MB** (big enough for chunked usage payloads and tool-call metadata, small enough to reject a pathological event), cumulative stream bytes at **50 MB** (hours of conversation tokens without unbounded memory growth), and event yield rate at **5,000 events/second** (roughly 100× real provider throughput). There is deliberately no "unlimited" option — bounded caps are the point.

Violations surface through the existing `AsyncThrowingStream` failure channel as ``SSEStreamError/eventTooLarge(_:)``, ``SSEStreamError/streamTooLarge(_:)``, or ``SSEStreamError/eventRateExceeded(_:)``, so backend retry and error-UI logic works unchanged. Tune globally via `BaseChatConfiguration.shared.sseStreamLimits`, or per backend via the `sseStreamLimits: SSEStreamLimits?` override on each ``SSECloudBackend`` instance:

```swift
BaseChatConfiguration.shared.sseStreamLimits = SSEStreamLimits(
    maxEventBytes: 64_000,
    maxTotalBytes: 1_000_000,
    maxEventsPerSecond: 500
)
```

## Model downloads

**Protected:** a malicious HuggingFace manifest (`../../Library/Preferences/…`) cannot write outside the models directory, and a previous-run crash cannot accumulate multi-GB temp files indefinitely.

``DownloadableModel/validate(fileName:)`` runs at the earliest point a filename enters the system (manifest parsing, Hub search results, snapshot downloads) and rejects: empty or `>= 255` characters (POSIX `NAME_MAX`); backslashes; control characters (C0, DEL, C1 — truncation hazards and invisible `U+0085 NEXT LINE` injection); `..` or `.` components; leading, trailing, or consecutive `/`; more than one `/` (only `<namespace>/<name>` is honoured); and any component starting with `.` (hides the file and collides with `.DS_Store`, `.git`). Placement into `modelsDirectory` additionally enforces a `.standardized.path` prefix check, so a filename that slips past structural validation still cannot escape the models directory.

**Stale-temp sweep.** `BackgroundDownloadManager.cleanupStaleTempFiles()` runs on launch from `reconnectBackgroundSession()` and removes regular files in `FileManager.default.temporaryDirectory` matching *all* of: prefix `"basechatkit-dl-"`, extension `"download"`, and modification date older than 24 hours. The prefix scopes the sweep; the 24-hour floor avoids clobbering an in-flight download the system's background transfer service hasn't handed back yet.

## Regex ReDoS

**Protected:** a filename crafted to induce catastrophic backtracking cannot freeze the UI.

`DownloadableModel.quantization` extracts the quant tag (`Q4_K_M`, `IQ2_XXS`, `BF16`) with a regex whose trailing `(?:_[A-Z0-9]+)` group is bounded to `{0,5}` repetitions, and the input is clipped to a 128-character prefix before evaluation. Real quant tags cap at two suffix components; the bounded envelope neutralises pathological input.

## Prompt template hardening

**Protected:** a user cannot paste a fake `<|im_start|>system` turn and reshape the conversation.

GGUF models do not apply their own chat templates, so ``PromptTemplate`` wraps messages in the format the model was trained on (ChatML, Llama 3, Mistral, Alpaca, Gemma, Phi). Before each user message is interpolated, the template strips the special tokens specific to that format (`<|im_start|>`, `[INST]`, `<|eot_id|>`, …). Narrow defense against *structural* injection, not semantic jailbreaks.

## Observability

`Log.*` calls use `privacy: .private` for credentials, prompts, and user content; `privacy: .public` is reserved for stable identifiers (host names, file names, task phases, `OSStatus` codes). Mirror the same discipline in your own code — Console redaction is lost the moment a single `%{public}s` leaks a secret.

## Prompt injection — explicit disclaimer

**Prompt injection is inherent to the LLM-chat domain and BaseChatKit does not solve it.** The framework does not sanitize the semantic boundary between system prompt and user content — only the structural special-token strip above. System prompts are not a security boundary; any user or pasted document can override them. Tool calls, retrieved content, and pasted web pages are untrusted input from the model's perspective — treat them the way you would a cross-origin iframe.

Mitigations, in roughly increasing cost: use structured message formats (provider `tool_use` payloads, JSON schemas) rather than stuffing instructions into prose; add a content filter before user-uploaded documents reach the model; keep tool capability scopes small — a calendar reader is much cheaper to expose than email send.

## Out of scope

The framework does not attempt to protect against DNS rebinding; user-installed MITM certificates (corporate proxies, jailbreak tweaks); a compromised host OS or jailbroken/rooted device; side-channel attacks on shared Mac user sessions; supply-chain attacks on pre-built model weights (GGUF SHA manifest verification is **roadmap**); or physical-access and social-engineering attacks (also excluded from our disclosure scope in [SECURITY.md](https://github.com/roryford/BaseChatKit/blob/main/.github/SECURITY.md)).

## Roadmap

The remaining hardening item not yet on `main` is **GGUF signed-manifest verification** — checking a signed SHA manifest for downloaded weights so a MITM or a tampered mirror cannot swap in a different model file under the same filename. Tracked in [issue #367](https://github.com/roryford/BaseChatKit/issues/367).

## Reporting a vulnerability

Report suspected vulnerabilities through [GitHub Security Advisories](https://github.com/roryford/BaseChatKit/security/advisories/new) — do not open public issues. Full policy: [SECURITY.md](https://github.com/roryford/BaseChatKit/blob/main/.github/SECURITY.md).

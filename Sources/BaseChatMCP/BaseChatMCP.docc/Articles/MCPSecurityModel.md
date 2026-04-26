# MCP security model

`BaseChatMCP` applies security controls at descriptor, transport, auth, and tool-bridge layers.

## Descriptor boundaries

- ``MCPServerDescriptor.dataDisclosure``: app-facing disclosure string.
- ``MCPToolFilter``: allow/deny lists and `maxToolCount` cap.
- ``MCPApprovalPolicy``: per-call/turn/session approval semantics.
- `toolNamespace`: prevents ambiguous cross-server tool names.

## Transport and protocol guards

- Max message bytes and JSON nesting depth (`MCPClientConfiguration`).
- Request timeout and max concurrent in-flight requests.
- SSE stream limits from shared configuration.
- Oversize and malformed payloads map to ``MCPError`` (`oversizeMessage`, `malformedMetadata`, etc.).

## OAuth hardening

- HTTPS is required for OAuth metadata and token endpoints.
- Authorization headers are sent only to same-origin HTTPS resources.
- Authorization headers are emitted only for bearer tokens with header-safe token bytes.
- Issuer mismatches are rejected.
- PKCE (`S256`) and state validation are enforced.
- `invalid_grant` refresh failures clear stored tokens and force re-authorization.
- DCR is attempted only when explicitly allowed and safely falls back for public clients.
- Token storage is abstracted via ``MCPOAuthTokenStore`` (`.keychain` default).

## Not-yet-supported areas

- MCP resources/prompts/logging are surfaced as ``MCPCapabilities`` flags only; this module currently bridges tools (`tools/list`, `tools/call`) into `ToolRegistry`.

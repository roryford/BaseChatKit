# Built-in MCP Catalog

`MCPCatalog` is compiled only when the `MCPBuiltinCatalog` trait is enabled.

## Trait

```bash
swift test --filter BaseChatMCPTests --disable-default-traits --traits MCPBuiltinCatalog
```

## Purpose

The built-in catalog ships conservative defaults for common providers:

- `MCPCatalog.notion`
- `MCPCatalog.linear`
- `MCPCatalog.github`

Each descriptor includes:

- stable descriptor IDs for persistence/audit continuity
- HTTPS streamable endpoint defaults
- OAuth descriptor defaults
- explicit `dataDisclosure` copy for user-facing consent surfaces

Treat these as templates: apps can clone and override hostnames, scopes, timeouts, and tool filters to match deployment policy.

```swift
var github = MCPCatalog.github
github = MCPServerDescriptor(
    id: github.id,
    displayName: github.displayName,
    transport: github.transport,
    authorization: github.authorization,
    toolNamespace: "github-org-a",
    resourceURL: github.resourceURL,
    initializationTimeout: .seconds(10),
    dataDisclosure: github.dataDisclosure,
    toolFilter: .init(mode: .allowList, names: ["issues.list", "pull_request.get"])
)
```

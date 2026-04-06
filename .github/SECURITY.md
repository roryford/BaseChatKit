# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.2.x   | Yes       |
| < 0.2   | No        |

## Reporting a Vulnerability

**Please do not open public issues for security vulnerabilities.**

### Preferred: GitHub Security Advisories

Report vulnerabilities through [GitHub Security Advisories](https://github.com/roryford/BaseChatKit/security/advisories/new). This keeps the discussion private until a fix is available.

### Alternative: Email

If you cannot use Security Advisories, email **security@basechatkit.dev** with:

- A description of the vulnerability
- Steps to reproduce
- Affected versions
- Any potential mitigations you've identified

## Response Timeline

| Step | Target |
|------|--------|
| Acknowledge report | 48 hours |
| Triage and severity assessment | 5 business days |
| Patch release | 30 days |

We may adjust timelines for complex issues, but will keep you informed of progress.

## Scope

The following areas are considered in-scope for security reports:

- **Credential handling** — API key storage, Keychain usage, key exposure in logs or memory
- **Network security** — certificate pinning, TLS validation, request integrity
- **Input validation** — prompt injection, path traversal, malformed model responses
- **Local data** — SwiftData persistence, conversation export, temporary files

## Out of Scope

- Vulnerabilities in upstream dependencies (report these to the relevant project)
- Attacks requiring physical access to the device
- Local denial-of-service (e.g., loading a model that exhausts memory)
- Social engineering

## Acknowledgement

We credit reporters in the release notes for confirmed vulnerabilities, unless you prefer to remain anonymous. Let us know your preference when reporting.

## Disclosure Policy

We follow coordinated disclosure. Once a fix is released, we publish a security advisory with full details. We ask reporters to wait until the advisory is published before disclosing publicly.

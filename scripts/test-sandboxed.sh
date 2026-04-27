#!/usr/bin/env bash
# scripts/test-sandboxed.sh — Run BaseChatKit's local-only test suites under
# `sandbox-exec` with a net-deny profile.
#
# Phase 5 of #714. `DenyAllURLProtocol` (Phase 1, PR #715) intercepts
# `URLSession` traffic but cannot see `Network.framework`, raw BSD sockets,
# `getaddrinfo(3)`, mDNS/Bonjour, `CFStream`, or `Process.launch` of curl.
# This script adds a second runtime layer at the **OS sandbox boundary** —
# any outbound network attempt by the test binary triggers a sandbox
# violation, killing the test before it can leak.
#
# Why a separate script (instead of a CI matrix entry):
#   - sandbox-exec is macOS-only; running it inside `swift test` would skip
#     on Linux but burn CI minutes resolving the `swift test` invocation
#     anyway. A standalone harness lets the build-mode CI matrix gate it
#     cheaply (macOS-only step).
#   - The `swift test` driver itself spawns helpers that do not need network
#     for `--disable-default-traits` runs. Wrapping the driver, not each
#     test, keeps the sandbox profile small and audit-friendly.
#
# Usage:
#   scripts/test-sandboxed.sh              # runs the default offline filters
#   scripts/test-sandboxed.sh --filter X   # forwards args to swift test
#
# The script is intentionally conservative about what it runs under the
# sandbox: only suites that should be **provably free** of network egress
# (the offline build-mode set). Suites that legitimately exercise network
# (real Ollama, MCP E2E) belong outside this harness.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_FILE="${TMPDIR:-/tmp}/bck-deny-net-$$.sb"

cleanup() {
    rm -f "$PROFILE_FILE"
}
trap cleanup EXIT

# ── Platform gate ─────────────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "skip: sandbox-exec is macOS-only (host: $(uname -s))" >&2
    exit 0
fi

if [[ ! -x /usr/bin/sandbox-exec ]]; then
    echo "error: /usr/bin/sandbox-exec not found — required for net-deny isolation" >&2
    exit 1
fi

# ── Profile ───────────────────────────────────────────────────────────────────
#
# `(deny network*)` covers the `network` action class:
#   - network-outbound  (TCP/UDP connect, sendto)
#   - network-inbound   (bind/listen)
#   - network-bind
#   - network*-resolution (gates getaddrinfo / DNS)
#
# `(allow file*)` keeps file I/O open — the test binary needs to read the
# package, write build artifacts, and read fixtures. We also allow `mach*`
# and `ipc*` so XCTest's reporter and Process subreaping work; without these
# the swift-test driver crashes on startup, which is a noisy failure mode
# that hides whether any actual network attempt happened.

cat > "$PROFILE_FILE" <<'SBPL'
(version 1)
(allow default)
(deny network*)
SBPL

# ── Run swift test under the sandbox ──────────────────────────────────────────
#
# Default filter set is the offline-mode CI suites — same set as the
# pre-push checklist in CLAUDE.md. Callers can override by passing args.

if [[ $# -eq 0 ]]; then
    set -- \
        --disable-default-traits \
        --filter BaseChatTestSupportTests
fi

echo "==> sandbox-exec profile: $PROFILE_FILE"
cat "$PROFILE_FILE"
echo "==> swift test args: $*"
echo

cd "$PACKAGE_DIR"

# Note: `swift` resolves to whichever toolchain is on PATH; the sandbox
# inherits the parent process environment (PATH included), so xcrun-shimmed
# `swift` works without further wiring.
exec /usr/bin/sandbox-exec -f "$PROFILE_FILE" /usr/bin/env swift test "$@"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cat <<'INFO'
record-mcp-fixtures.sh runs offline, deterministic fixture capture.
It does not call provider APIs or require credentials.
INFO

"$ROOT/scripts/regenerate-mcp-fixtures.sh" "$@"

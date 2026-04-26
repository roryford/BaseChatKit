#!/usr/bin/env bash
#
# Fixture-driven test for `migrate-uimm-imports.sh`.
#
# For each `fixtures/<id>-<name>-input.swift`, copy it into a scratch
# directory, run the codemod against the scratch dir, and diff the result
# against `fixtures/<id>-<name>-expected.swift`.
#
# Run via: scripts/migrate-uimm-imports-tests/run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
CODEMOD="$SCRIPT_DIR/../migrate-uimm-imports.sh"

if [ ! -x "$CODEMOD" ]; then
    echo "error: codemod not found or not executable: $CODEMOD" >&2
    exit 1
fi

failures=0
total=0

for input in "$FIXTURES_DIR"/*-input.swift; do
    total=$((total + 1))
    base=$(basename "$input" -input.swift)
    expected="$FIXTURES_DIR/${base}-expected.swift"
    if [ ! -f "$expected" ]; then
        echo "FAIL [$base]: missing expected fixture: $expected"
        failures=$((failures + 1))
        continue
    fi

    scratch=$(mktemp -d)
    trap 'rm -rf "$scratch"' EXIT

    cp "$input" "$scratch/file.swift"
    "$CODEMOD" "$scratch" >/dev/null

    if diff -u "$expected" "$scratch/file.swift" > "$scratch/diff" 2>&1; then
        echo "PASS [$base]"
    else
        echo "FAIL [$base]:"
        cat "$scratch/diff"
        failures=$((failures + 1))
    fi

    rm -rf "$scratch"
    trap - EXIT
done

echo
echo "Results: $((total - failures))/$total passed"
exit "$failures"

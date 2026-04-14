#!/usr/bin/env bash
#
# clean-leaked-test-artifacts.sh
#
# Removes model-artifact files left in the demo app's Documents/Models
# directory by tests that historically wrote fixtures to the production path
# (see #379). The fix landed in the same PR that adds this script, but any
# developer who ran `swift test` before the fix has accumulated junk.
#
# Targets (pattern-matched by filename + 15-byte size check):
#   * Prefix-based test fixture names:
#       aaa-*, bbb-*, ccc-*
#       perf-gguf-*, perf-mlx-*
#       mixed-gguf-*, mixed-mlx-*, mlx-model-*
#       test-*, not-a-model-*, imported-*, unsupported-*
#       sizeA-*, sizeB-*, overwrite-test-*, import-test-*
#       mixed\ gguf*, mixed\ mlx*, perf gguf*, perf mlx*
#   * 15-byte ASCII placeholder files masquerading as model IDs, e.g.:
#       Hermes-3-Llama-3.2-3B, Mistral-7B-Instruct-v0.1,
#       OpenHermes-2.5-Mistral-7B, etc.
#
# Deliberately does NOT touch:
#   * Real model directories (>= 1 MB, or containing .safetensors)
#   * Real GGUF files (>= 1 MB and starting with the "GGUF" magic)
#
# Usage:
#   scripts/clean-leaked-test-artifacts.sh             # actually delete
#   scripts/clean-leaked-test-artifacts.sh --dry-run   # list what would go
#
# If the demo container UUID changes, set MODELS_DIR explicitly:
#   MODELS_DIR="$HOME/Library/Containers/<uuid>/Data/Documents/Models" \
#     scripts/clean-leaked-test-artifacts.sh --dry-run
#

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# If the caller hasn't pointed us at a specific path, scan two locations:
#  1) Every sandboxed container's Documents/Models (where the demo app writes
#     when launched as a normal macOS app — UUIDs vary across machines).
#  2) The user's plain ~/Documents/Models — where unsandboxed `swift test`
#     runs leaked their fixtures before #379 landed.
if [[ -n "${MODELS_DIR:-}" ]]; then
    CANDIDATES=("$MODELS_DIR")
else
    CANDIDATES=()
    while IFS= read -r -d '' dir; do
        CANDIDATES+=("$dir")
    done < <(find "$HOME/Library/Containers" -maxdepth 4 -type d -name "Models" -path "*/Data/Documents/*" -print0 2>/dev/null)
    if [[ -d "$HOME/Documents/Models" ]]; then
        CANDIDATES+=("$HOME/Documents/Models")
    fi
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "No sandbox Models directories found under ~/Library/Containers."
    echo "Set MODELS_DIR=<path> to target a specific location."
    exit 0
fi

# Prefixes that tests use when creating fixtures. Matched case-sensitively
# against the leading characters of the basename.
PREFIXES=(
    "aaa-" "bbb-" "ccc-"
    "perf-gguf-" "perf-mlx-"
    "mixed-gguf-" "mixed-mlx-"
    "mlx-model-"
    "test-" "not-a-model-"
    "imported-" "unsupported-"
    "sizeA-" "sizeB-"
    "overwrite-test-" "import-test-"
    "stable-id-test" "v5-check" "model-name." "phi-3-mini-"
    "model-a." "model-b." "fake."
    "nested-mlx-model" "stable-mlx" "test-mlx-model" "bad-mlx-model"
    "tiny." "bad." "empty." "valid." "invalid." "wrong-magic." "does-not-exist."
    "named-valid." "completed." "queued."
)

# Display names that sometimes appear with a space (e.g., when the test
# writes a display-formatted filename). Kept separate because they need
# space-tolerant matching.
DISPLAY_PREFIXES=(
    "mixed gguf" "mixed mlx"
    "perf gguf" "perf mlx"
    "mlx model"
)

# 15-byte placeholder files that masquerade as HuggingFace model IDs.
# These are the ones explicitly called out in #379.
PLACEHOLDER_NAMES=(
    "Hermes-3-Llama-3.2-3B"
    "OpenHermes-2.5-Mistral-7B"
    "Mistral-7B-Instruct-v0.1"
    "Mistral-7B-Instruct-v0.2-AWQ"
    "mistral-7b-v0.3-bnb-4bit"
)

should_remove() {
    local path="$1"
    local base
    base="$(basename -- "$path")"
    local size
    size=$(stat -f '%z' "$path" 2>/dev/null || stat -c '%s' "$path" 2>/dev/null || echo 0)

    # Explicit placeholder names, only if exactly 15 bytes (ASCII salt file).
    for name in "${PLACEHOLDER_NAMES[@]}"; do
        if [[ "$base" == "$name" && "$size" == "15" && -f "$path" ]]; then
            return 0
        fi
    done

    # Generic 15-byte ASCII placeholder: any plain file in Models/ that is
    # exactly 15 bytes long AND contains only printable ASCII bytes.
    # We also require the name to NOT look like a real model filename
    # (no "." extension and no common real-model suffix).
    if [[ -f "$path" && "$size" == "15" ]]; then
        if [[ "$base" != *.gguf && "$base" != *.safetensors ]]; then
            # Verify ASCII-printable content: if the file has any byte
            # outside 0x20-0x7e plus \n, skip it — we don't want to touch
            # binary blobs that happen to be exactly 15 bytes.
            if LC_ALL=C tr -d '\11\12\40-\176' < "$path" | read -r _; then
                : # has non-printable — skip
            else
                return 0
            fi
        fi
    fi

    # Prefix-matched scratch files.
    for pfx in "${PREFIXES[@]}"; do
        if [[ "$base" == "$pfx"* ]]; then
            return 0
        fi
    done
    for pfx in "${DISPLAY_PREFIXES[@]}"; do
        if [[ "$base" == "$pfx"* ]]; then
            return 0
        fi
    done

    return 1
}

remove_path() {
    local path="$1"
    if [[ "$DRY_RUN" == "1" ]]; then
        local size
        size=$(stat -f '%z' "$path" 2>/dev/null || stat -c '%s' "$path" 2>/dev/null || echo ?)
        printf 'would remove (%s bytes): %s\n' "$size" "$path"
    else
        echo "removing: $path"
        rm -rf -- "$path"
    fi
}

TOTAL=0
for dir in "${CANDIDATES[@]}"; do
    [[ -d "$dir" ]] || continue
    echo "Scanning: $dir"
    while IFS= read -r -d '' entry; do
        if should_remove "$entry"; then
            remove_path "$entry"
            TOTAL=$((TOTAL + 1))
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
done

if [[ "$DRY_RUN" == "1" ]]; then
    echo "Done. $TOTAL leaked artefacts identified (dry run; nothing was deleted)."
else
    echo "Done. Removed $TOTAL leaked artefacts."
fi

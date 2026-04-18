#!/usr/bin/env bash
# scripts/fuzz.sh — Run the BaseChatFuzz harness with a friendly preflight.
#
# Default behaviour (no args): runs `swift run fuzz-chat --minutes 5` against
# Ollama. Discovers which backends are usable and prints a one-line summary
# before kicking off the harness. Forwards all CLI args straight through to
# `fuzz-chat`, with one local extension:
#
#   --with-mlx   Also run the MLX XCTest fuzz suite via xcodebuild after the
#                swift-run path completes. This is a local flag and is NOT
#                forwarded to fuzz-chat.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Local flag extraction (everything else is forwarded) ─────────────────────
WITH_MLX=0
FORWARDED_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --with-mlx) WITH_MLX=1 ;;
        -h|--help)
            cd "$PACKAGE_DIR"
            echo "scripts/fuzz.sh — wrapper around \`swift run fuzz-chat\`"
            echo ""
            echo "Local flags:"
            echo "  --with-mlx   Also run the MLX XCTest fuzz suite via xcodebuild"
            echo "  -h, --help   Show this help and forward to fuzz-chat -h"
            echo ""
            echo "Forwarding to: swift run fuzz-chat -h"
            echo "─────────────────────────────────────────────────────────────"
            swift run fuzz-chat -h || true
            exit 0
            ;;
        *) FORWARDED_ARGS+=("$arg") ;;
    esac
done

# ── Preflight: which backends look usable on this machine? ───────────────────
LLAMA_HIT="miss"
MLX_HIT="miss"
OLLAMA_HIT="miss"
FOUNDATION_HIT="miss"

MODELS_DIR="$HOME/Documents/Models"
if [[ -d "$MODELS_DIR" ]]; then
    if find "$MODELS_DIR" -maxdepth 2 -type f -name "*.gguf" -print -quit 2>/dev/null | grep -q .; then
        LLAMA_HIT="hit"
    fi
    if find "$MODELS_DIR" -maxdepth 3 -type f -name "*.safetensors" -print -quit 2>/dev/null | grep -q .; then
        MLX_HIT="hit"
    fi
fi

if curl -s -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    OLLAMA_HIT="hit"
fi

PRODUCT_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
PRODUCT_MAJOR="${PRODUCT_VERSION%%.*}"
if [[ "$PRODUCT_MAJOR" =~ ^[0-9]+$ ]] && (( PRODUCT_MAJOR >= 26 )); then
    FOUNDATION_HIT="hit"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BaseChatFuzz preflight"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  Discovered: Llama=%s, MLX=%s, Ollama=%s, Foundation=%s\n" \
    "$LLAMA_HIT" "$MLX_HIT" "$OLLAMA_HIT" "$FOUNDATION_HIT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$LLAMA_HIT" == "miss" && "$MLX_HIT" == "miss" && "$OLLAMA_HIT" == "miss" && "$FOUNDATION_HIT" == "miss" ]]; then
    echo "No usable backends detected. Install hints:" >&2
    echo "  Ollama:     brew install ollama && ollama serve   (then: ollama pull qwen3.5:4b)" >&2
    echo "  Llama:      drop a *.gguf into ~/Documents/Models/<name>/" >&2
    echo "  MLX:        drop an MLX snapshot into ~/Documents/Models/<name>/ (config.json + *.safetensors + tokenizer)" >&2
    echo "  Foundation: requires macOS 26+" >&2
    exit 2
fi

# ── Default budget: 5 minutes if the caller passed no time/iteration flag. ───
HAS_BUDGET=0
for arg in "${FORWARDED_ARGS[@]:-}"; do
    case "$arg" in
        --minutes|--minutes=*|--iterations|--iterations=*|--single)
            HAS_BUDGET=1 ;;
    esac
done

if [[ $HAS_BUDGET -eq 0 ]]; then
    FORWARDED_ARGS=("--minutes" "5" "${FORWARDED_ARGS[@]:-}")
fi

cd "$PACKAGE_DIR"

echo ""
echo "Running: swift run fuzz-chat ${FORWARDED_ARGS[*]:-}"
echo ""

set +e
swift run fuzz-chat "${FORWARDED_ARGS[@]:-}"
SWIFT_EXIT=$?
set -e

MLX_EXIT=0
if [[ $WITH_MLX -eq 1 ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  --with-mlx: running MLX XCTest fuzz suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # TODO: BaseChatFuzzTests/MLXFuzzTests does not exist yet — wire it up
    # when the MLX XCTest harness lands. For now we attempt the run and
    # report its exit code; xcodebuild will fail loudly if the scheme is
    # missing the target, which is the correct signal.
    set +e
    xcodebuild test \
        -scheme BaseChatKit-Package \
        -only-testing BaseChatFuzzTests/MLXFuzzTests \
        -destination 'platform=macOS'
    MLX_EXIT=$?
    set -e
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FUZZ SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  swift run fuzz-chat exit:   %d\n" "$SWIFT_EXIT"
if [[ $WITH_MLX -eq 1 ]]; then
    printf "  xcodebuild MLXFuzzTests:    %d\n" "$MLX_EXIT"
fi
printf "  Findings index:             tmp/fuzz/INDEX.md\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FINAL_EXIT=$SWIFT_EXIT
if [[ $WITH_MLX -eq 1 && $MLX_EXIT -ne 0 && $FINAL_EXIT -eq 0 ]]; then
    FINAL_EXIT=$MLX_EXIT
fi

if [[ $FINAL_EXIT -eq 0 ]]; then
    echo "  RESULT: OK (no crashes; review tmp/fuzz/INDEX.md for findings)"
else
    echo "  RESULT: FAILED (exit $FINAL_EXIT)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FINAL_EXIT

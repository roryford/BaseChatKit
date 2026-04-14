#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/cleanup-test-model-artifacts.sh [--dry-run|--apply]

Scans production model directories for files and directories leaked by older
tests, then prints the matches. Pass --apply to delete them.
EOF
}

mode="dry-run"
case "${1:-}" in
  "")
    ;;
  --dry-run)
    ;;
  --apply)
    mode="apply"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

is_known_test_artifact() {
  local name="$1"

  [[ "$name" == "test-refresh-model.gguf" ]] && return 0
  [[ "$name" == "test-stale-model.gguf" ]] && return 0

  [[ "$name" =~ ^(test|mlx-model|not-a-model|mixed-gguf|mixed-mlx|sizeA|sizeB|import-test|overwrite-test|imported|unsupported|perf-gguf-[0-9]+|perf-mlx-[0-9]+)-[0-9A-Fa-f-]{36}(\.[A-Za-z0-9]+)?$ ]] && return 0
  [[ "$name" =~ ^(aaa|bbb|ccc)-[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{36}\.gguf$ ]] && return 0

  return 1
}

declare -a search_roots=()
documents_models="$HOME/Documents/Models"
if [[ -d "$documents_models" ]]; then
  search_roots+=("$documents_models")
fi

containers_root="$HOME/Library/Containers"
if [[ -d "$containers_root" ]]; then
  while IFS= read -r models_dir; do
    search_roots+=("$models_dir")
  done < <(find "$containers_root" -type d -path "*/Data/Documents/Models" -print 2>/dev/null)
fi

if [[ ${#search_roots[@]} -eq 0 ]]; then
  echo "No production Models directories found."
  exit 0
fi

declare -a matches=()
for root in "${search_roots[@]}"; do
  while IFS= read -r candidate; do
    name="${candidate##*/}"
    if is_known_test_artifact "$name"; then
      matches+=("$candidate")
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
done

if [[ ${#matches[@]} -eq 0 ]]; then
  echo "No leaked test artifacts found."
  exit 0
fi

printf 'Found %d leaked test artifact(s):\n' "${#matches[@]}"
printf ' - %s\n' "${matches[@]}"

if [[ "$mode" != "apply" ]]; then
  echo "Dry run only. Re-run with --apply to delete these paths."
  exit 0
fi

for path in "${matches[@]}"; do
  rm -rf -- "$path"
done

echo "Removed leaked test artifacts."

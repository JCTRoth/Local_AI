#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage: generate_category_scripts.sh [options]

Options:
  --models-root DIR   Root models directory (default: ../models)
  --out-dir DIR       Directory to write generated run_*.sh (default: repo root)
  --threads N         Threads for server (default: 8)
  --api-key KEY       API key to inject (default: from env OPENAI_API_KEY)
  --no-force          Do not pass --force to generator
  --dry-run           Pass --dry-run to generator (do not write files)
  --max-depth N       Max depth for find (default: 10)
  -h, --help          Show this help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_ROOT="$REPO_ROOT/models"
OUT_DIR="$REPO_ROOT"
THREADS=8
API_KEY="${OPENAI_API_KEY:-sk-local-coding}"
FORCE=true
DRY_RUN=false
MAX_DEPTH=10
GENERATOR_EXTRA=()

while [ "${#}" -gt 0 ]; do
  case "$1" in
    --models-root) MODELS_ROOT="$2"; shift 2;;
    --out-dir) OUT_DIR="$2"; shift 2;;
    --threads) THREADS="$2"; shift 2;;
    --api-key) API_KEY="$2"; shift 2;;
    --no-force) FORCE=false; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --max-depth) MAX_DEPTH="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *)
      # Forward unknown options to the underlying generator (except --port-start)
      if [ "${1#--}" != "$1" ]; then
        # option-like
        if [ "$2" ] && [ "${2:0:1}" != "-" ]; then
          GENERATOR_EXTRA+=("$1" "$2"); shift 2
        else
          GENERATOR_EXTRA+=("$1"); shift
        fi
      else
        # positional or unexpected; forward as-is
        GENERATOR_EXTRA+=("$1"); shift
      fi
      ;;
  esac
done

CATEGORIES=("main_model" "autocomplete_model" "rerank_model")
PORTS=(8080 8081 8082)

GENERATOR="$SCRIPT_DIR/generate_start_scripts.sh"

if [ ! -x "$GENERATOR" ] && [ ! -f "$GENERATOR" ]; then
  echo "Error: generator not found at $GENERATOR"
  exit 1
fi

for i in "${!CATEGORIES[@]}"; do
  cat_name="${CATEGORIES[$i]}"
  port="${PORTS[$i]}"
  model_root="$MODELS_ROOT/$cat_name"

  if [ ! -d "$model_root" ]; then
    echo "Skipping $cat_name: $model_root does not exist"
    continue
  fi

  # Destination folder for generated scripts for this category
  CATEGORY_OUT_DIR="$OUT_DIR/starter_scripts/$cat_name"
  mkdir -p "$CATEGORY_OUT_DIR"

  echo "Generating scripts for category '$cat_name' (model root: $model_root) -> port $port"

  cmd=(bash "$GENERATOR" --model-root "$model_root" --out-dir "$CATEGORY_OUT_DIR" --port-start "$port" --threads "$THREADS" --api-key "$API_KEY" --max-depth "$MAX_DEPTH")
  if [ "$FORCE" = true ]; then
    cmd+=(--force)
  fi
  if [ "$DRY_RUN" = true ]; then
    cmd+=(--dry-run)
  fi

  # Filter out any --port-start passed in GENERATOR_EXTRA (we control per-category ports)
  FILTERED_EXTRA=()
  i=0
  while [ $i -lt ${#GENERATOR_EXTRA[@]} ]; do
    e="${GENERATOR_EXTRA[$i]}"
    if [[ "$e" == --port-start ]]; then
      # skip this and the next value (if any)
      i=$((i+2))
      continue
    elif [[ "$e" == --port-start=* ]]; then
      i=$((i+1))
      continue
    else
      FILTERED_EXTRA+=("$e")
      i=$((i+1))
    fi
  done

  if [ ${#FILTERED_EXTRA[@]} -gt 0 ]; then
    cmd+=("${FILTERED_EXTRA[@]}")
  fi

  echo "Running: ${cmd[*]}"
  if ! "${cmd[@]}"; then
    echo "Warning: generator failed for category $cat_name"
    continue
  fi
  echo "Done for $cat_name"
  echo
done

echo "All done. Generated scripts (if not dry-run) are in: $OUT_DIR"
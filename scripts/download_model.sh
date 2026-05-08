#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage: download_model.sh [options] REPO_ID [...]

Downloads one or more Hugging Face model repositories into the `models/` folder.

Examples:
  download_model.sh Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF
  download_model.sh --dry-run Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF
  echo "Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF" | download_model.sh --dry-run

Options:
  --local-dir-root DIR   Root folder to place downloads (default: ./models)
  --cache-dir DIR        Hugging Face cache dir (passed to `hf download`)
  --max-workers N        Max workers for `hf download` (default: 8)
  --force-download       Pass `--force-download` to `hf download`
  --token TOKEN          HF token to pass via `--token`
  --dry-run              Print the commands instead of executing
  -h,--help              Show this help
EOF
}

# Defaults
LOCAL_DIR_ROOT="./models"
CACHE_DIR=""
MAX_WORKERS=8
FORCE_DOWNLOAD=false
DRY_RUN=false
TOKEN=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local-dir-root) LOCAL_DIR_ROOT="$2"; shift 2;;
    --cache-dir) CACHE_DIR="$2"; shift 2;;
    --max-workers) MAX_WORKERS="$2"; shift 2;;
    --force-download) FORCE_DOWNLOAD=true; shift;;
    --token) TOKEN="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "Unknown option: $1"; usage; exit 1;;
    *) break;;
  esac
done

# Collect repo ids from args, stdin, or interactive prompt
repos=()
if [ "$#" -eq 0 ]; then
  if [ -t 0 ]; then
    # Interactive mode
    echo "Interactive mode: enter model repo IDs, one per line. Submit an empty line to finish."
    while true; do
      printf '> '
      if ! IFS= read -r line; then
        break
      fi
      # Strip CR and trim
      line="${line%%$'\r'}"
      line="$(echo "$line" | xargs)"
      [ -z "$line" ] && break
      repos+=("$line")
    done
  else
    # Read from stdin (piped)
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%$'\r'}"
      line="$(echo "$line" | xargs)"
      [ -z "$line" ] && continue
      repos+=("$line")
    done
  fi
else
  repos=("$@")
fi

if [ "${#repos[@]}" -eq 0 ]; then
  echo "No repo IDs provided." >&2
  usage
  exit 1
fi

mkdir -p "$LOCAL_DIR_ROOT"

for repo in "${repos[@]}"; do
  repo=$(echo "$repo" | xargs)
  [ -z "$repo" ] && continue

  # Derive a local folder name from the repo id. Prefer the repo basename.
  if [[ "$repo" == */* ]]; then
    base=${repo##*/}
    owner=${repo%%/*}
    target_dir="$LOCAL_DIR_ROOT/$base"
  else
    # No slash — sanitize the whole string
    safe=$(echo "$repo" | sed 's/[^A-Za-z0-9._-]/_/g')
    target_dir="$LOCAL_DIR_ROOT/$safe"
  fi

  cmd=( hf download "$repo" --local-dir "$target_dir" --max-workers "$MAX_WORKERS" )
  [ -n "$CACHE_DIR" ] && cmd+=( --cache-dir "$CACHE_DIR" )
  $FORCE_DOWNLOAD && cmd+=( --force-download )
  [ -n "$TOKEN" ] && cmd+=( --token "$TOKEN" )

  if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: ${cmd[*]}"
  else
    echo "Downloading $repo -> $target_dir"
    mkdir -p "$target_dir"
    "${cmd[@]}"
  fi
done

exit 0

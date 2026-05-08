#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage: generate_start_scripts.sh [options]

Options:
  --model-root DIR     Directory to scan for model files (default: .)
  --out-dir DIR        Directory to write run_*.sh scripts (default: .)
  --port-start N       Starting port (default: 8080)
  --threads N          Number of threads to pass to server (default: 8)
  --api-key KEY        API key (default: sk-local-coding)
  --llama-server PATH  Path to llama-server binary (default: ./llama-b9058-vulcan/llama-server)
                                 If not provided the script will search for a folder
                                 starting with `llama-` in the project root and use
                                 its `llama-server` binary if found.
  --max-depth N        Max search depth for find (default: 3)
  --force              Overwrite existing scripts
  --dry-run            Print actions but don't write files
  -h, --help           Show this help
EOF
}

# Defaults
MODEL_ROOT='.'
OUT_DIR='.'
PORT_START=8080
THREADS=8
API_KEY='sk-local-coding'
LLAMA_SERVER='./llama-b9058-vulcan/llama-server'
MAX_DEPTH=10
FORCE=false
DRY_RUN=false
MIN_SIZE_BYTES=10485760

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model-root) MODEL_ROOT="$2"; shift 2;;
    --out-dir) OUT_DIR="$2"; shift 2;;
    --port-start) PORT_START="$2"; shift 2;;
    --threads) THREADS="$2"; shift 2;;
    --api-key) API_KEY="$2"; shift 2;;
    --llama-server) LLAMA_SERVER="$2"; shift 2;;
    --max-depth) MAX_DEPTH="$2"; shift 2;;
    --force) FORCE=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

mkdir -p "$OUT_DIR"

# Auto-detect a llama-* folder in the project root and use its llama-server binary
# if the configured LLAMA_SERVER does not exist or is not executable.
if [ ! -x "$LLAMA_SERVER" ]; then
  for d in ./llama-*; do
    if [ -d "$d" ]; then
      cand="$d/llama-server"
      if [ -x "$cand" ] || [ -f "$cand" ]; then
        LLAMA_SERVER="$cand"
        break
      fi
    fi
  done
fi

echo "Using llama server: $LLAMA_SERVER"

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Find candidate files and write "size<TAB>path" lines to tmpfile
find "$MODEL_ROOT" -maxdepth "$MAX_DEPTH" -type f -iname '*.gguf' -size +"${MIN_SIZE_BYTES}"c -print0 |
while IFS= read -r -d '' file; do
  if [ ! -f "$file" ]; then continue; fi
  size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  printf "%012d\t%s\n" "$size" "$file" >>"$tmpfile"
done

if [ ! -s "$tmpfile" ]; then
  echo "No candidate model files found under $MODEL_ROOT"
  exit 0
fi

mapfile -t files_sorted < <(sort -rn "$tmpfile" | cut -f2- -d $'\t')

created=()
skipped=()
PORT=${PORT_START}

for file in "${files_sorted[@]}"; do
  base=$(basename -- "$file")
  name=${base%.*}
  safe=$(echo "$name" | tr -cs '[:alnum:]' '_' | tr '[:upper:]' '[:lower:]')
  safe=${safe##_}
  safe=${safe%%_}
  [ -z "$safe" ] && safe='model'
  script="$OUT_DIR/run_${safe}.sh"

  if command -v realpath >/dev/null 2>&1; then
    rel_model=$(realpath --relative-to="$OUT_DIR" "$file" 2>/dev/null || printf "%s" "$file")
  else
    rel_model="$file"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "Would write: $script -> $rel_model (port $PORT)"
    PORT=$((PORT + 1))
    continue
  fi

  if [ -e "$script" ] && [ "$FORCE" != true ]; then
    skipped+=("$script")
    PORT=$((PORT + 1))
    continue
  fi

  cat >"$script" <<EOF
#!/bin/bash
usage() {
  cat <<USAGE
Usage: $0 [--help|-h] [--stop]

Options:
  --help, -h   Show this help
  --stop       Stop any running llama-server using port ${PORT}
If no option is provided the script starts the server in the foreground.
USAGE
}

if [ "\${1-}" = "--help" ] || [ "\${1-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "\${1-}" = "--stop" ]; then
  echo "Stopping server on port ${PORT}..."
  # Find processes that include the port flag for this server invocation
  pids=\$(pgrep -f "llama-server .*--port ${PORT}" || true)
  if [ -z "\$pids" ]; then
    echo "No running process found for port ${PORT}"
    exit 0
  fi
  echo "Killing: \$pids"
  echo "\$pids" | xargs -r kill
  exit 0
fi

# Determine threads: allow --threads parameter, otherwise compute from CPU layout
THREADS_ARG=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --threads)
      THREADS_ARG="\$2"
      shift 2
      ;;
    --help|-h|--stop)
      # handled above; consume and continue
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "\$THREADS_ARG" ]; then
  THREADS_ARG=\$(($(lscpu -p | grep -v '^#' | sort -u -t, -k 2,4 | wc -l)-1))
fi

# Pin to first 12 physical cores for performance
taskset -c 0-11 ${LLAMA_SERVER} -m ./${rel_model} \\
    --port ${PORT} \\
    -ngl 99 \\
    -fa on \\
    --threads \${THREADS_ARG} \\
    --batch-size 1024 \\
    --ubatch-size 256 \\
    --ctx-size 16384 \\
    --mlock \\
    --api-key ${API_KEY}
EOF

  chmod +x "$script"
  created+=("$script")
  PORT=$((PORT + 1))
done

if [ "${#created[@]}" -gt 0 ]; then
  echo "Created scripts:"
  for p in "${created[@]}"; do echo "  $p"; done
fi
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "Skipped (exists):"
  for p in "${skipped[@]}"; do echo "  $p"; done
fi

exit 0

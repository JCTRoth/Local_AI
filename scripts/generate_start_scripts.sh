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

# Sampling/default parameters (can be set on generator CLI and will be injected
# as defaults into each generated run_*.sh script)
TEMP=""
TOP_K=""
TOP_P=""
MIN_P=""
SAMPLERS=""
N_PREDICT=""
TYP_P=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model-root) MODEL_ROOT="$2"; shift 2;;
    --out-dir) OUT_DIR="$2"; shift 2;;
    --port-start) PORT_START="$2"; shift 2;;
    --threads) THREADS="$2"; shift 2;;
    --api-key) API_KEY="$2"; shift 2;;
    --llama-server) LLAMA_SERVER="$2"; shift 2;;
    --max-depth) MAX_DEPTH="$2"; shift 2;;
      --temp) TEMP="$2"; shift 2;;
      --top-k) TOP_K="$2"; shift 2;;
      --top-p) TOP_P="$2"; shift 2;;
      --min-p) MIN_P="$2"; shift 2;;
      --samplers) SAMPLERS="$2"; shift 2;;
      --n-predict) N_PREDICT="$2"; shift 2;;
      --typ_p) TYP_P="$2"; shift 2;;
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

# Record an absolute form of the detected LLAMA_SERVER for embedding into
# generated scripts. The generated scripts will still attempt to find a
# runnable llama-server at runtime if this embedded path is not valid.
if command -v realpath >/dev/null 2>&1; then
  LLAMA_SERVER_ABS=$(realpath "$LLAMA_SERVER" 2>/dev/null || printf "%s" "$LLAMA_SERVER")
elif command -v readlink >/dev/null 2>&1; then
  LLAMA_SERVER_ABS=$(readlink -f "$LLAMA_SERVER" 2>/dev/null || printf "%s" "$LLAMA_SERVER")
else
  LLAMA_SERVER_ABS="$LLAMA_SERVER"
fi

echo "Using llama server: $LLAMA_SERVER_ABS"

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
  dir=$(dirname -- "$file")
  # Prefer the top-level folder name under MODEL_ROOT as the script name (e.g. "autocomplete_model")
  if command -v realpath >/dev/null 2>&1; then
    rel_dir=$(realpath --relative-to="$MODEL_ROOT" "$dir" 2>/dev/null || printf "%s" "$dir")
  else
    case "$dir" in
      "$MODEL_ROOT"|"${MODEL_ROOT}/"*) rel_dir="${dir#$MODEL_ROOT/}" ;;
      *) rel_dir="$dir" ;;
    esac
  fi
  category=$(printf "%s" "$rel_dir" | cut -d/ -f1)
  if [ -z "$category" ] || [ "$category" = "." ]; then
    category=$(basename -- "$dir")
  fi
  safe=$(echo "$category" | tr -cs '[:alnum:]_' '_' | tr '[:upper:]' '[:lower:]')
  safe=${safe##_}
  safe=${safe%%_}
  [ -z "$safe" ] && safe='model'
  script="$OUT_DIR/run_${safe}.sh"

  if command -v realpath >/dev/null 2>&1; then
    abs_model=$(realpath "$file" 2>/dev/null || printf "%s" "$file")
    rel_model=$(realpath --relative-to="$OUT_DIR" "$file" 2>/dev/null || printf "%s" "$file")
  else
    abs_model="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
    rel_model="$file"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "Would write: $script -> $rel_model (port $PORT)"
    continue
  fi

  if [ -e "$script" ] && [ "$FORCE" != true ]; then
    skipped+=("$script")
    continue
  fi

  # Prepare sampling/default assignments to inject into generated script
  if [ -n "$TEMP" ]; then TEMP_ASSIGN="TEMP_ARG=\"$TEMP\""; else TEMP_ASSIGN='TEMP_ARG=""'; fi
  if [ -n "$TOP_K" ]; then TOP_K_ASSIGN="TOP_K_ARG=\"$TOP_K\""; else TOP_K_ASSIGN='TOP_K_ARG=""'; fi
  if [ -n "$TOP_P" ]; then TOP_P_ASSIGN="TOP_P_ARG=\"$TOP_P\""; else TOP_P_ASSIGN='TOP_P_ARG=""'; fi
  if [ -n "$MIN_P" ]; then MIN_P_ASSIGN="MIN_P_ARG=\"$MIN_P\""; else MIN_P_ASSIGN='MIN_P_ARG=""'; fi
  if [ -n "$SAMPLERS" ]; then SAMPLERS_ASSIGN="SAMPLERS_ARG='${SAMPLERS}'"; else SAMPLERS_ASSIGN='SAMPLERS_ARG=""'; fi
  if [ -n "$N_PREDICT" ]; then N_PREDICT_ASSIGN="N_PREDICT_ARG=\"$N_PREDICT\""; else N_PREDICT_ASSIGN='N_PREDICT_ARG=""'; fi
  if [ -n "$TYP_P" ]; then TYP_P_ASSIGN="TYP_P_ARG=\"$TYP_P\""; else TYP_P_ASSIGN='TYP_P_ARG=""'; fi
  THREADS_ASSIGN="THREADS_ARG=\"$THREADS\""

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

  # Determine category alias from current working directory (PWD).
  CANDIDATES=("autocomplete_model" "main_model" "rerank_model")
  CATEGORY_ALIAS=""
  for c in "\${CANDIDATES[@]}"; do
    if [[ "\$PWD" == *"/\$c"* ]] || [[ "\$(basename "\$PWD")" == "\$c" ]]; then
      CATEGORY_ALIAS="\$c"
      break
    fi
  done

  if [ -n "\$CATEGORY_ALIAS" ]; then
    echo "Detected category alias from PWD: \$CATEGORY_ALIAS"
    # Set shell alias for this category so you can invoke by category name
    alias \$CATEGORY_ALIAS="\$0"
    echo "Created alias: \$CATEGORY_ALIAS -> \$0"
  else
    echo "Warning: current working directory does not contain any of: \${CANDIDATES[*]}. CATEGORY_ALIAS will be empty." >&2
    CATEGORY_ALIAS=""
  fi

  # Inject generator-provided sampling defaults (values expanded at generation time)
  $TEMP_ASSIGN
  $TOP_K_ASSIGN
  $TOP_P_ASSIGN
  $MIN_P_ASSIGN
  $SAMPLERS_ASSIGN
  $N_PREDICT_ASSIGN
  $TYP_P_ASSIGN

  # Pre-populate THREADS_ARG from generator (--threads passed to generator)
  $THREADS_ASSIGN

  EXTRA_ARGS=()
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --threads)
        THREADS_ARG="\$2"; shift 2;;
      --temp|--temperature)
        TEMP_ARG="\$2"; shift 2;;
      --top-k)
        TOP_K_ARG="\$2"; shift 2;;
      --top-p)
        TOP_P_ARG="\$2"; shift 2;;
      --min-p)
        MIN_P_ARG="\$2"; shift 2;;
      --samplers)
        SAMPLERS_ARG="\$2"; shift 2;;
      --n-predict)
        N_PREDICT_ARG="\$2"; shift 2;;
      --typ_p)
        TYP_P_ARG="\$2"; shift 2;;
      --xtc_*)
        EXTRA_ARGS+=("\$1" "\$2"); shift 2;;
      --*)
        if [ -n "\$2" ] && [ "\${2:0:1}" != "-" ]; then
          EXTRA_ARGS+=("\$1" "\$2"); shift 2
        else
          EXTRA_ARGS+=("\$1"); shift
        fi
        ;;
      *)
        EXTRA_ARGS+=("\$1"); shift;;
    esac
  done

  if [ -z "\$THREADS_ARG" ]; then
    THREADS_ARG=\$(lscpu -p | grep -v '^#' | sort -u -t, -k 2,4 | wc -l)
  fi

  # Build sampling flags from variables
  SAMPLING_FLAGS=""
  if [ -n "\$TEMP_ARG" ]; then SAMPLING_FLAGS="\$SAMPLING_FLAGS --temp \$TEMP_ARG"; fi
  if [ -n "\$TOP_K_ARG" ]; then SAMPLING_FLAGS="\$SAMPLING_FLAGS --top-k \$TOP_K_ARG"; fi
  if [ -n "\$TOP_P_ARG" ]; then SAMPLING_FLAGS="\$SAMPLING_FLAGS --top-p \$TOP_P_ARG"; fi
  if [ -n "\$MIN_P_ARG" ]; then SAMPLING_FLAGS="\$SAMPLING_FLAGS --min-p \$MIN_P_ARG"; fi
  if [ -n "\$SAMPLERS_ARG" ]; then SAMPLING_FLAGS="\$SAMPLING_FLAGS --samplers '\$SAMPLERS_ARG'"; fi
  if [ -n "\$N_PREDICT_ARG" ]; then SAMPLING_FLAGS="\$SAMPLING_FLAGS --n-predict \$N_PREDICT_ARG"; fi
  if [ -n "\$TYP_P_ARG" ]; then SAMPLING_FLAGS="\$SAMPLING_FLAGS --typ_p \$TYP_P_ARG"; fi

  # First, check the common admin port 127.0.0.1:8080 (e.g. Continue/dashboard or proxy).
  # If a service responds there, abort to avoid starting/loading models while another
  # server is active on that admin port.
  if command -v curl >/dev/null 2>&1; then
    if curl -s --connect-timeout 2 "http://127.0.0.1:8080" >/dev/null 2>&1; then
      echo "Error: Detected existing HTTP service at http://127.0.0.1:8080. Not starting the model to avoid conflicts."
      exit 1
    fi
  elif command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 8080 >/dev/null 2>&1; then
      echo "Error: Detected listening service on port 8080. Not starting the model to avoid conflicts."
      exit 1
    fi
  else
    if (echo > /dev/tcp/127.0.0.1/8080) >/dev/null 2>&1; then
      echo "Error: Port 8080 appears to be in use. Not starting the model."
      exit 1
    fi
  fi

  # Check if an HTTP server is already responding on this script's target port (127.0.0.1:${PORT}).
  # If so, do not start the model to avoid accidental double-binding or conflicts.
  if command -v curl >/dev/null 2>&1; then
    if curl -s --connect-timeout 2 "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
      echo "Error: HTTP server detected at http://127.0.0.1:${PORT}. Not starting the model to avoid conflicts."
      exit 1
    fi
  elif command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 ${PORT} >/dev/null 2>&1; then
      echo "Error: Port ${PORT} is already in use (listening). Not starting the model."
      exit 1
    fi
  else
    # Fallback using bash /dev/tcp
    if (echo > /dev/tcp/127.0.0.1/${PORT}) >/dev/null 2>&1; then
      echo "Error: Port ${PORT} appears to be in use. Not starting the model."
      exit 1
    fi
  fi

  # Determine llama-server at runtime so the script can be invoked from anywhere.
  SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
  EMBEDDED_LLAMA_SERVER="${LLAMA_SERVER_ABS}"
  MODEL_PATH="${abs_model}"

  find_llama_server() {
    if [ -n "\$EMBEDDED_LLAMA_SERVER" ]; then
      if [ -x "\$EMBEDDED_LLAMA_SERVER" ]; then
        printf "%s" "\$EMBEDDED_LLAMA_SERVER"
        return 0
      fi
      if [ -x "\$SCRIPT_DIR/\$EMBEDDED_LLAMA_SERVER" ]; then
        printf "%s" "\$SCRIPT_DIR/\$EMBEDDED_LLAMA_SERVER"
        return 0
      fi
    fi
    cur="\$SCRIPT_DIR"
    while [ "\$cur" != "/" ] && [ -n "\$cur" ]; do
      for d in "\$cur"/llama-*; do
        if [ -x "\$d/llama-server" ]; then
          printf "%s" "\$d/llama-server"
          return 0
        fi
      done
      cur="\$(dirname "\$cur")"
    done
    if command -v llama-server >/dev/null 2>&1; then
      command -v llama-server
      return 0
    fi
    return 1
  }

  LLAMA_SERVER_RUNTIME="\$(find_llama_server || true)"
  if [ -z "\$LLAMA_SERVER_RUNTIME" ]; then
    echo "Error: llama-server executable not found. Please build it or set the path."
    exit 1
  fi

  # Build alias flag from category if detected
  ALIAS_FLAG=""
  if [ -n "\$CATEGORY_ALIAS" ]; then
    ALIAS_FLAG="--alias \$CATEGORY_ALIAS"
  fi

  # Pin to first 12 physical cores for performance
  taskset -c 0-11 "\$LLAMA_SERVER_RUNTIME" -m "${abs_model}" \\
    --port ${PORT} \\
    \${ALIAS_FLAG} \\
  -ngl 99 \\
  -fa on \\
  --threads \${THREADS_ARG} \\
  --batch-size 1024 \\
  --ubatch-size 256 \\
  --ctx-size 16384 \\
  --mlock \\
  \${SAMPLING_FLAGS} \\
  "\${EXTRA_ARGS[@]}" \\
  --api-key ${API_KEY}
EOF

  chmod +x "$script"
  created+=("$script")
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

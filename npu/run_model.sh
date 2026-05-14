#!/usr/bin/env bash
set -euo pipefail

# run_model.sh
#  - accepts either a model file or a model directory
#  - autodiscovers RyzenAI ONNX GenAI model folders (looks for genai_config.json)
#  - chooses a free port (default 8080) and logs the chosen port
#  - attempts to start `ryzenai-server` if available and logs its output
#
# Usage:
#   ./run_model.sh <path-to-model-file-or-directory> [port]
# Examples:
#   ./run_model.sh ./models/Qwen2.5-Coder-..._npu_16K/
#   ./run_model.sh ./models/Qwen2.5-Coder-.../model.onnx 8082

usage() {
    echo "Usage: $0 <path_to_model_file_or_directory> [port]"
    exit 1
}

if [ "$#" -lt 1 ]; then
    usage
fi

RAW_PATH="$1"
REQUESTED_PORT="${2:-}"

# Resolve to absolute path (best-effort)
if command -v realpath >/dev/null 2>&1; then
    MODEL_ARG=$(realpath -m "$RAW_PATH")
else
    MODEL_ARG="$RAW_PATH"
fi

if [ ! -e "$MODEL_ARG" ]; then
    echo "Error: Model path does not exist: $MODEL_ARG" >&2
    exit 1
fi

MODEL_DIR=""
MODEL_FILE=""
MODEL_TYPE=""

# If a directory was given, try to find genai_config.json (RyzenAI) or an ONNX file
if [ -d "$MODEL_ARG" ]; then
    # prefer genai_config.json in the directory
    if [ -f "$MODEL_ARG/genai_config.json" ]; then
        MODEL_DIR="$MODEL_ARG"
        MODEL_FILE="$MODEL_ARG/genai_config.json"
        MODEL_TYPE="ryzenai"
    else
        # look for genai_config.json recursively (depth 3)
        GENAI=$(find "$MODEL_ARG" -maxdepth 3 -type f -name "genai_config.json" -print -quit 2>/dev/null || true)
        if [ -n "$GENAI" ]; then
            MODEL_DIR=$(dirname "$GENAI")
            MODEL_FILE="$GENAI"
            MODEL_TYPE="ryzenai"
        else
            # fallback: look for any .onnx file
            ONNX=$(find "$MODEL_ARG" -maxdepth 3 -type f -iname "*.onnx" -print -quit 2>/dev/null || true)
            if [ -n "$ONNX" ]; then
                MODEL_DIR=$(dirname "$ONNX")
                MODEL_FILE="$ONNX"
                MODEL_TYPE="onnx"
            fi
        fi
    fi
else
    # Path is a file
    MODEL_DIR=$(dirname "$MODEL_ARG")
    MODEL_FILE="$MODEL_ARG"
    base=$(basename "$MODEL_ARG")
    case "${base,,}" in
        genai_config.json)
            MODEL_TYPE="ryzenai"
            ;;
        *.onnx)
            MODEL_TYPE="onnx"
            ;;
        *.pt|*.pth)
            MODEL_TYPE="pytorch"
            ;;
        *.h5|*.keras)
            MODEL_TYPE="tensorflow"
            ;;
        *)
            echo "Error: Unsupported model file type: $MODEL_ARG" >&2
            exit 1
            ;;
    esac
fi

if [ -z "$MODEL_TYPE" ]; then
    echo "Error: Could not autodetect a model in: $RAW_PATH" >&2
    echo "Looked for genai_config.json and .onnx files." >&2
    exit 1
fi

# Choose a starting port (default 8080) and find a free port
DEFAULT_PORT=8080
if [ -n "$REQUESTED_PORT" ]; then
    PORT_CAND=$REQUESTED_PORT
else
    PORT_CAND=$DEFAULT_PORT
fi

port_in_use() {
    local p=$1
    if command -v ss >/dev/null 2>&1; then
        ss -ltn | awk '{print $4}' | grep -E ":${p}$" >/dev/null 2>&1
        return $?
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -E ":${p}$" >/dev/null 2>&1
        return $?
    else
        # No reliable check available; optimistically assume free
        return 1
    fi
}

PORT=""
for p in $(seq "$PORT_CAND" $((PORT_CAND + 99))); do
    if ! port_in_use "$p"; then
        PORT=$p
        break
    fi
done

if [ -z "$PORT" ]; then
    echo "Error: no free port found in range $PORT_CAND..$((PORT_CAND + 99))" >&2
    exit 1
fi

# Prepare log file in model directory
LOG_DIR="${MODEL_DIR:-.}"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/run_model_${PORT}.log"

echo "[INFO] $(date -Is) run_model.sh starting" | tee -a "$LOGFILE"
echo "[INFO] Model arg: $RAW_PATH" | tee -a "$LOGFILE"
echo "[INFO] Detected model type: $MODEL_TYPE" | tee -a "$LOGFILE"
echo "[INFO] Model dir: $MODEL_DIR" | tee -a "$LOGFILE"
echo "[INFO] Model file: $MODEL_FILE" | tee -a "$LOGFILE"
echo "[INFO] Chosen port: $PORT" | tee -a "$LOGFILE"

if [ "$MODEL_TYPE" = "ryzenai" ]; then
    # Try to find ryzenai-server binary
    RYZEN_BIN=""
    if command -v ryzenai-server >/dev/null 2>&1; then
        RYZEN_BIN=$(command -v ryzenai-server)
    else
        # Look for an executable named ryzenai-server in the workspace
        RYZEN_BIN=$(find "$(pwd)" -type f -name ryzenai-server -executable -print -quit 2>/dev/null || true)
    fi

    if [ -z "$RYZEN_BIN" ]; then
        echo "[WARN] ryzenai-server not found in PATH or workspace. Cannot start backend." | tee -a "$LOGFILE"
        echo "[INFO] Intended port (not started): $PORT" | tee -a "$LOGFILE"
        echo "[INFO] To run the model, install ryzenai-server or start via Lemonade/lemond. Example:" | tee -a "$LOGFILE"
        echo "  - Install Lemonade Server and ryzenai backend, then use the server's /api/v1/load API or 'lemond' to load the model." | tee -a "$LOGFILE"
        echo "[INFO] To track this script in git, add '!/npu/run_model.sh' to .gitignore or use 'git add -f'" | tee -a "$LOGFILE"
        exit 2
    fi

    # Attempt to extract ctx-size from genai_config.json if jq is available
    CTX_SIZE=16384
    if command -v jq >/dev/null 2>&1 && [ -f "$MODEL_DIR/genai_config.json" ]; then
        val=$(jq -r '.model.decoder.session_options.provider_options[0].RyzenAI.hybrid_opt_max_seq_length // empty' "$MODEL_DIR/genai_config.json" 2>/dev/null || true)
        if [ -n "$val" ] && [ "$val" != "null" ]; then
            CTX_SIZE="$val"
        fi
    fi

    echo "[INFO] Starting ryzenai-server: $RYZEN_BIN -m \"$MODEL_DIR\" --port $PORT --ctx-size $CTX_SIZE" | tee -a "$LOGFILE"

    # Start background process and redirect output to logfile
    "$RYZEN_BIN" -m "$MODEL_DIR" --port "$PORT" --ctx-size "$CTX_SIZE" >>"$LOGFILE" 2>&1 &
    PID=$!
    echo "[INFO] Started ryzenai-server PID=$PID" | tee -a "$LOGFILE"

    # Wait for health endpoint
    echo "[INFO] Waiting for server health on http://127.0.0.1:$PORT/health ..." | tee -a "$LOGFILE"
    for i in $(seq 1 30); do
        if command -v curl >/dev/null 2>&1; then
            if curl -s "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
                echo "[INFO] Server is ready on port $PORT" | tee -a "$LOGFILE"
                echo "$PORT" > "$LOG_DIR/.run_model_port"
                exit 0
            fi
        else
            # No curl; fallback to checking listening port
            if port_in_use "$PORT"; then
                echo "[INFO] Port $PORT is now listening (server may be up)" | tee -a "$LOGFILE"
                echo "$PORT" > "$LOG_DIR/.run_model_port"
                exit 0
            fi
        fi
        sleep 1
    done

    echo "[ERROR] Server did not become healthy within timeout. See $LOGFILE" | tee -a "$LOGFILE" >&2
    exit 1

else
    # Non-RyzenAI flows: we provide informational load / introspect, not serving
    if [ "$MODEL_TYPE" = "onnx" ]; then
        if ! command -v python3 >/dev/null 2>&1; then
            echo "Error: python3 is required to inspect ONNX models." | tee -a "$LOGFILE" >&2
            exit 1
        fi
        echo "[INFO] Inspecting ONNX model metadata (no server will be started)" | tee -a "$LOGFILE"
        python3 - <<PY >>"$LOGFILE" 2>&1
import onnxruntime as ort
sess=ort.InferenceSession("$MODEL_FILE")
name = sess.get_inputs()[0].name
shape = sess.get_inputs()[0].shape
dtype = sess.get_inputs()[0].type
print(f"ONNX input: {name} {shape} {dtype}")
PY
        echo "[INFO] Introspected model saved to $LOGFILE" | tee -a "$LOGFILE"
        echo "$PORT" > "$LOG_DIR/.run_model_port"
        exit 0
    else
        echo "[INFO] Model type '$MODEL_TYPE' is supported for inspection only by this script." | tee -a "$LOGFILE"
        echo "$PORT" > "$LOG_DIR/.run_model_port"
        exit 0
    fi
fi

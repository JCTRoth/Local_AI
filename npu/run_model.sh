#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/runtime"
REGISTRY_FILE="$RUNTIME_DIR/model_registry.tsv"

MODEL_INPUT=""
MODEL_DIR=""
MODEL_FILE=""
MODEL_TYPE=""
MODEL_NAME=""
SAFE_MODEL_NAME=""
LOGS_DIR=""
CURRENT_LOG_FILE=""
PORT=""
PID=""
CTX_SIZE="16384"
BACKEND_LABEL=""
BACKEND_COMMAND=""
NPU_USAGE_SOURCE=""
NPU_USAGE_VALUE=""
RYZEN_AI_RUNTIME_ROOT=""

pick_first_existing_path() {
    local candidate=''
    for candidate in "$@"; do
        if [ -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

prepend_env_value() {
    local variable_name=$1
    shift
    local current_value="${!variable_name:-}"
    local candidate=''

    for candidate in "$@"; do
        if [ -n "$candidate" ]; then
            if [ -n "$current_value" ]; then
                current_value="$candidate:$current_value"
            else
                current_value="$candidate"
            fi
        fi
    done

    printf -v "$variable_name" '%s' "$current_value"
}

candidate_ryzen_ai_roots() {
    local candidate=''

    for candidate in \
        "${RYZEN_AI_INSTALLATION_PATH:-}" \
        /opt/ryzen_ai \
        /opt/ryzen_ai/venv \
        "$HOME/ryzen_ai_env" \
        "$HOME/ryzen_ai" \
        "$HOME/.ryzen_ai"; do
        if [ -n "$candidate" ] && [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
        fi
    done | awk '!seen[$0]++'
}

configure_ryzen_ai_runtime_environment() {
    local root=''
    local bin_dir=''
    local site_packages_dir=''
    local provider_lib=''
    local xrt_common_dir=''
    local path_entries=()
    local ld_entries=()

    if [ "$MODEL_TYPE" != 'ryzenai' ]; then
        return 0
    fi

    while IFS= read -r root; do
        if [ -n "$root" ]; then
            break
        fi
    done < <(candidate_ryzen_ai_roots)

    if [ -z "$root" ]; then
        log_msg WARN 'Ryzen AI model detected, but no local Ryzen AI runtime root was found.'
        log_msg INFO 'Looked for /opt/ryzen_ai and the user-level ryzen_ai_env installation.'
        return 0
    fi

    RYZEN_AI_RUNTIME_ROOT="$root"
    export RYZEN_AI_INSTALLATION_PATH="$root"

    bin_dir=$(pick_first_existing_path "$root/bin" "$root/venv/bin" || true)
    site_packages_dir=$(pick_first_existing_path \
        "$root/lib64/python3.12/site-packages" \
        "$root/lib/python3.12/site-packages" \
        "$root/venv/lib64/python3.12/site-packages" \
        "$root/venv/lib/python3.12/site-packages" || true)

    if [ -n "$bin_dir" ]; then
        path_entries+=("$bin_dir")
    fi
    if [ -n "$site_packages_dir" ] && [ -d "$site_packages_dir/bin" ]; then
        path_entries+=("$site_packages_dir/bin")
    fi

    if [ -n "$site_packages_dir" ]; then
        provider_lib=$(pick_first_existing_path \
            "$site_packages_dir/onnxruntime/capi/libonnxruntime_providers_ryzenai.so" || true)
        if [ -n "$provider_lib" ] && [ -f "$provider_lib" ]; then
            export RYZENAI_EP_PATH="$provider_lib"
            ld_entries+=("$(dirname "$provider_lib")")
        fi
        if [ -d "$site_packages_dir/voe/lib" ]; then
            ld_entries+=("$site_packages_dir/voe/lib")
        fi
    fi

    xrt_common_dir="$SCRIPT_DIR/../source/xdna-driver/xrt/build/Release/runtime_src/core/common"
    if [ -d "$xrt_common_dir" ]; then
        ld_entries+=("$xrt_common_dir")
    fi

    if [ "${#path_entries[@]}" -gt 0 ]; then
        prepend_env_value PATH "${path_entries[@]}"
        export PATH
    fi
    if [ "${#ld_entries[@]}" -gt 0 ]; then
        prepend_env_value LD_LIBRARY_PATH "${ld_entries[@]}"
        export LD_LIBRARY_PATH
    fi

    if [ -n "$bin_dir" ]; then
        export XRT_DIR="$bin_dir"
    fi
    export DD_ROOT="$MODEL_DIR"
    export DD_CACHE="$MODEL_DIR/.cache"

    log_msg INFO "Ryzen AI runtime root: $RYZEN_AI_RUNTIME_ROOT"
    if [ -n "${RYZENAI_EP_PATH:-}" ]; then
        log_msg INFO "Ryzen AI custom-ops library: $RYZENAI_EP_PATH"
    fi
    if [ -n "$xrt_common_dir" ] && [ -d "$xrt_common_dir" ]; then
        log_msg INFO "Added local XRT runtime path: $xrt_common_dir"
    fi
}

find_standard_tool() {
    local tool_name=$1
    local candidate=''
    local root=''

    if command -v "$tool_name" >/dev/null 2>&1; then
        command -v "$tool_name"
        return 0
    fi

    while IFS= read -r root; do
        for candidate in \
            "$root/bin/$tool_name" \
            "$root/venv/bin/$tool_name" \
            "$root/xrt/bin/$tool_name" \
            "$root/tools/$tool_name" \
            "$root/tools/bin/$tool_name"; do
            if [ -x "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done < <(candidate_ryzen_ai_roots)

    for candidate in /opt/xilinx/xrt/bin/$tool_name /opt/xilinx/xrt/bin/unwrapped/$tool_name; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

usage() {
    cat <<'EOF'
Usage:
    ./run_model.sh <path_to_model_file_or_directory> [port]
    ./run_model.sh start [options] <path_to_model_file_or_directory>
    ./run_model.sh list
    ./run_model.sh status
    ./run_model.sh stats
    ./run_model.sh stop (--pid PID | --port PORT | --model PATH | --all)

Start options:
    --port PORT                 Preferred port. If busy, the next free port is used.
    --wait-seconds N           Seconds to wait for the service to become reachable (default: 60)
    --backend-command CMD      Custom shell command used to start the backend.
                                                         Available environment variables inside CMD:
                                                             LOCAL_AI_MODEL_PATH
                                                             LOCAL_AI_MODEL_DIR
                                                             LOCAL_AI_MODEL_FILE
                                                             LOCAL_AI_PORT
                                                             LOCAL_AI_CTX_SIZE
                                                             LOCAL_AI_LOG_FILE
                                                         Placeholder aliases are also replaced before launch:
                                                             __MODEL_PATH__ __MODEL_DIR__ __MODEL_FILE__ __PORT__ __CTX_SIZE__
    --npu-usage-threshold N    Refuse startup above this NPU usage percent (default: 70)
    --skip-npu-usage-check     Skip the NPU usage check entirely
    -h, --help                 Show this help

Examples:
    ./run_model.sh npu/models/Qwen2.5-Coder-0.5B-Instruct_rai_1.7.1_npu_4K/
    ./run_model.sh start --port 8090 --skip-npu-usage-check \
        --backend-command 'python3 -m http.server "$LOCAL_AI_PORT" --bind 127.0.0.1 --directory "$LOCAL_AI_MODEL_DIR"' \
        npu/models/Qwen2.5-Coder-0.5B-Instruct_rai_1.7.1_npu_4K/
    ./run_model.sh list
    ./run_model.sh stats
    ./run_model.sh stop --port 8090
EOF
}

ensure_runtime_dir() {
    mkdir -p "$RUNTIME_DIR"
    touch "$REGISTRY_FILE"
}

timestamp_iso() {
    date -Is
}

timestamp_unix() {
    date +%s
}

log_msg() {
    local level=$1
    shift
    local message="$*"
    local line="[$level] $(timestamp_iso) $message"
    if [ -n "$CURRENT_LOG_FILE" ]; then
        printf '%s\n' "$line" | tee -a "$CURRENT_LOG_FILE"
    else
        printf '%s\n' "$line"
    fi
}

log_error() {
    log_msg ERROR "$*" >&2
}

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

resolve_path() {
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

sanitize_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]_.-' '_' | sed 's/^_*//; s/_*$//'
}

port_in_use() {
    local check_port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ":${check_port}$" >/dev/null 2>&1
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -E ":${check_port}$" >/dev/null 2>&1
        return $?
    fi
    return 1
}

choose_port() {
    local start_port=$1
    local probe
    for probe in $(seq "$start_port" $((start_port + 99))); do
        if ! port_in_use "$probe"; then
            printf '%s\n' "$probe"
            return 0
        fi
    done
    return 1
}

extract_ctx_size() {
    local value=""
    if [ "$MODEL_TYPE" = "ryzenai" ] && command -v python3 >/dev/null 2>&1 && [ -f "$MODEL_DIR/genai_config.json" ]; then
        value=$(python3 - "$MODEL_DIR/genai_config.json" <<'PY'
import json
import sys

path = sys.argv[1]
try:
        with open(path, 'r', encoding='utf-8') as handle:
                data = json.load(handle)
        options = data.get('model', {}).get('decoder', {}).get('session_options', {}).get('provider_options', [])
        for item in options:
                config = item.get('RyzenAI') or {}
                for key in ('hybrid_opt_max_seq_length', 'max_length_for_kv_cache'):
                        raw = config.get(key)
                        if raw not in (None, ''):
                                print(raw)
                                raise SystemExit(0)
        fallback = data.get('search', {}).get('max_length')
        if fallback not in (None, ''):
                print(fallback)
except Exception:
        pass
PY
)
    fi

    if [ -n "$value" ] && is_uint "$value"; then
        printf '%s\n' "$value"
    else
        printf '16384\n'
    fi
}

detect_model() {
    local raw_path=$1
    MODEL_INPUT=$(resolve_path "$raw_path")
    if [ ! -e "$MODEL_INPUT" ]; then
        printf 'Model path does not exist: %s\n' "$MODEL_INPUT" >&2
        exit 1
    fi

    MODEL_DIR=""
    MODEL_FILE=""
    MODEL_TYPE=""

    if [ -d "$MODEL_INPUT" ]; then
        if [ -f "$MODEL_INPUT/genai_config.json" ]; then
            MODEL_DIR="$MODEL_INPUT"
            MODEL_FILE="$MODEL_INPUT/genai_config.json"
            MODEL_TYPE="ryzenai"
        else
            local genai
            local onnx
            genai=$(find "$MODEL_INPUT" -maxdepth 3 -type f -name 'genai_config.json' -print -quit 2>/dev/null || true)
            if [ -n "$genai" ]; then
                MODEL_DIR=$(dirname "$genai")
                MODEL_FILE="$genai"
                MODEL_TYPE="ryzenai"
            else
                onnx=$(find "$MODEL_INPUT" -maxdepth 3 -type f -iname '*.onnx' -print -quit 2>/dev/null || true)
                if [ -n "$onnx" ]; then
                    MODEL_DIR=$(dirname "$onnx")
                    MODEL_FILE="$onnx"
                    MODEL_TYPE="onnx"
                fi
            fi
        fi
    else
        MODEL_DIR=$(dirname "$MODEL_INPUT")
        MODEL_FILE="$MODEL_INPUT"
        case "${MODEL_INPUT,,}" in
            */genai_config.json)
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
                printf 'Unsupported model file type: %s\n' "$MODEL_INPUT" >&2
                exit 1
                ;;
        esac
    fi

    if [ -z "$MODEL_TYPE" ] || [ -z "$MODEL_DIR" ] || [ -z "$MODEL_FILE" ]; then
        printf 'Could not detect a runnable model in: %s\n' "$raw_path" >&2
        printf 'Looked for genai_config.json and .onnx files.\n' >&2
        exit 1
    fi

    MODEL_NAME=$(basename "$MODEL_DIR")
    if [ -z "$MODEL_NAME" ] || [ "$MODEL_NAME" = "." ] || [ "$MODEL_NAME" = "/" ]; then
        MODEL_NAME=$(basename "${MODEL_FILE%.*}")
    fi
    SAFE_MODEL_NAME=$(sanitize_name "$MODEL_NAME")
    if [ -z "$SAFE_MODEL_NAME" ]; then
        SAFE_MODEL_NAME='model'
    fi
    CTX_SIZE=$(extract_ctx_size)
}

build_log_paths() {
    local started_epoch=$1
    LOGS_DIR="$MODEL_DIR/logs"
    mkdir -p "$LOGS_DIR"
    CURRENT_LOG_FILE="$LOGS_DIR/${started_epoch}_${SAFE_MODEL_NAME}.log"
    touch "$CURRENT_LOG_FILE"
    ln -sfn "$(basename "$CURRENT_LOG_FILE")" "$LOGS_DIR/latest.log" 2>/dev/null || true
}

prune_registry() {
    ensure_runtime_dir
    local tmp_file
    tmp_file=$(mktemp)

    while IFS=$'\t' read -r pid port model_name model_type model_path model_dir log_file backend started_at; do
        if [ -z "${pid:-}" ]; then
            continue
        fi
        if kill -0 "$pid" 2>/dev/null; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$pid" "$port" "$model_name" "$model_type" "$model_path" "$model_dir" "$log_file" "$backend" "$started_at" >>"$tmp_file"
        fi
    done < "$REGISTRY_FILE"

    mv "$tmp_file" "$REGISTRY_FILE"
}

append_registry_record() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$PID" "$PORT" "$MODEL_NAME" "$MODEL_TYPE" "$MODEL_INPUT" "$MODEL_DIR" "$CURRENT_LOG_FILE" "$BACKEND_LABEL" "$(timestamp_unix)" >>"$REGISTRY_FILE"
}

remove_registry_pid() {
    local target_pid=$1
    ensure_runtime_dir
    local tmp_file
    tmp_file=$(mktemp)

    while IFS=$'\t' read -r pid port model_name model_type model_path model_dir log_file backend started_at; do
        if [ -z "${pid:-}" ] || [ "$pid" = "$target_pid" ]; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$pid" "$port" "$model_name" "$model_type" "$model_path" "$model_dir" "$log_file" "$backend" "$started_at" >>"$tmp_file"
    done < "$REGISTRY_FILE"

    mv "$tmp_file" "$REGISTRY_FILE"
}

find_registry_by_model() {
    local target_path=$1
    prune_registry
    while IFS=$'\t' read -r pid port model_name model_type model_path model_dir log_file backend started_at; do
        if [ -z "${pid:-}" ]; then
            continue
        fi
        if [ "$model_path" = "$target_path" ] || [ "$model_dir" = "$target_path" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$pid" "$port" "$model_name" "$model_type" "$model_path" "$model_dir" "$log_file" "$backend" "$started_at"
            return 0
        fi
    done < "$REGISTRY_FILE"
    return 1
}

find_registry_by_port() {
    local target_port=$1
    prune_registry
    while IFS=$'\t' read -r pid port model_name model_type model_path model_dir log_file backend started_at; do
        if [ -z "${pid:-}" ]; then
            continue
        fi
        if [ "$port" = "$target_port" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$pid" "$port" "$model_name" "$model_type" "$model_path" "$model_dir" "$log_file" "$backend" "$started_at"
            return 0
        fi
    done < "$REGISTRY_FILE"
    return 1
}

parse_usage_percent_from_text() {
  python3 -c '
import re
import sys

text = sys.stdin.read()
lines = [line.strip() for line in text.splitlines() if line.strip()]

def candidates(source):
    preferred = [
        line for line in source
        if any(token in line.lower() for token in ("npu", "memory", "mem", "storage", "heap", "used", "usage", "alloc"))
    ]
    return preferred or source

for line in candidates(lines):
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*%", line)
    if match:
        print(match.group(1))
        raise SystemExit(0)

for line in candidates(lines):
    nums = [float(value) for value in re.findall(r"([0-9]+(?:\.[0-9]+)?)", line)]
    if len(nums) >= 2 and any(token in line.lower() for token in ("used", "alloc", "memory", "mem", "storage", "heap")):
        used, total = nums[0], nums[1]
        if total > 0 and used <= total:
            print((used * 100.0) / total)
            raise SystemExit(0)

raise SystemExit(1)
'
}

get_npu_usage_percent() {
    local raw=""
    local parsed=""
    local xrt_smi_bin=''
    local xbutil_bin=''
    NPU_USAGE_SOURCE=''
    NPU_USAGE_VALUE=''

    if [ -n "${LOCAL_AI_NPU_USAGE_COMMAND:-}" ]; then
        NPU_USAGE_SOURCE='LOCAL_AI_NPU_USAGE_COMMAND'
        raw=$(bash -lc "$LOCAL_AI_NPU_USAGE_COMMAND" 2>&1 || true)
    elif xrt_smi_bin=$(find_standard_tool xrt-smi); then
        NPU_USAGE_SOURCE='xrt-smi'
        raw=$($xrt_smi_bin examine 2>&1 || true)
        if [ -z "$raw" ]; then
            raw=$($xrt_smi_bin examine --report memory 2>&1 || true)
        fi
    elif xbutil_bin=$(find_standard_tool xbutil); then
        NPU_USAGE_SOURCE='xbutil'
        raw=$($xbutil_bin examine --report memory 2>&1 || true)
    else
        return 2
    fi

    if [ -z "$raw" ]; then
        return 3
    fi

    if ! parsed=$(printf '%s' "$raw" | parse_usage_percent_from_text); then
        return 4
    fi

    NPU_USAGE_VALUE="$parsed"
    return 0
}

ensure_npu_capacity() {
    local threshold=$1
    local skip_check=$2
    local status=0

    if [ "$MODEL_TYPE" != 'ryzenai' ]; then
        return 0
    fi

    if [ "$skip_check" = true ]; then
        log_msg WARN "Skipping NPU usage check by request."
        return 0
    fi

    local usage_percent=''
    if get_npu_usage_percent; then
        usage_percent="$NPU_USAGE_VALUE"
        log_msg INFO "NPU usage from ${NPU_USAGE_SOURCE}: ${usage_percent}%"
        if awk -v current="$usage_percent" -v limit="$threshold" 'BEGIN { exit !(current > limit) }'; then
            log_error "Refusing to start: NPU usage is ${usage_percent}% which is above the ${threshold}% limit."
            exit 1
        fi
        return 0
    else
        status=$?
    fi

    case "$status" in
        2)
            log_error "Refusing to start: cannot determine NPU usage because neither xrt-smi nor xbutil is available."
            log_msg INFO "Install the AMD XRT userspace tools or set LOCAL_AI_NPU_USAGE_COMMAND, or rerun with --skip-npu-usage-check after verifying the device manually."
            ;;
        *)
            log_error "Refusing to start: could not parse NPU usage from ${NPU_USAGE_SOURCE:-available telemetry}."
            log_msg INFO "Set LOCAL_AI_NPU_USAGE_COMMAND to a command that prints a percentage or rerun with --skip-npu-usage-check."
            ;;
    esac
    exit 1
}

find_ryzenai_server() {
    local candidate=""
    local root=""

    if candidate=$(find_standard_tool ryzenai-server); then
        printf '%s\n' "$candidate"
        return 0
    fi

    while IFS= read -r root; do
        candidate=$(find "$root" -maxdepth 5 -type f -name 'ryzenai-server' -perm -111 -print -quit 2>/dev/null || true)
        if [ -n "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(candidate_ryzen_ai_roots)

    for candidate in "$SCRIPT_DIR/bin/ryzenai-server" "$SCRIPT_DIR/ryzenai-server"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

build_shell_command() {
    local escaped=()
    local arg=""
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        escaped+=("$arg")
    done
    local joined=''
    local piece=''
    for piece in "${escaped[@]}"; do
        if [ -n "$joined" ]; then
            joined+=" "
        fi
        joined+="$piece"
    done
    printf '%s\n' "$joined"
}

resolve_backend() {
    local custom_command=${1:-}
    local ryzen_bin=""

    BACKEND_LABEL=''
    BACKEND_COMMAND=''

    if [ -n "$custom_command" ]; then
        BACKEND_LABEL='custom'
        BACKEND_COMMAND="$custom_command"
        BACKEND_COMMAND=${BACKEND_COMMAND//__MODEL_PATH__/$MODEL_INPUT}
        BACKEND_COMMAND=${BACKEND_COMMAND//__MODEL_DIR__/$MODEL_DIR}
        BACKEND_COMMAND=${BACKEND_COMMAND//__MODEL_FILE__/$MODEL_FILE}
        BACKEND_COMMAND=${BACKEND_COMMAND//__PORT__/$PORT}
        BACKEND_COMMAND=${BACKEND_COMMAND//__CTX_SIZE__/$CTX_SIZE}
        return 0
    fi

    if [ "$MODEL_TYPE" = 'ryzenai' ]; then
        ryzen_bin=$(find_ryzenai_server || true)
        if [ -n "$ryzen_bin" ]; then
            BACKEND_LABEL='ryzenai-server'
            BACKEND_COMMAND=$(build_shell_command "$ryzen_bin" -m "$MODEL_DIR" --port "$PORT" --ctx-size "$CTX_SIZE")
            return 0
        fi
    fi

    return 1
}

explain_missing_backend() {
    if [ "$MODEL_TYPE" = 'ryzenai' ]; then
        log_error "No runnable NPU server backend is installed for this model."
        log_msg INFO "The current machine has NPU model folders and the amdxdna kernel driver, but the script cannot find ryzenai-server or another API server backend."
        log_msg INFO "AMD's Linux docs describe an LLM benchmark flow under RYZEN_AI_INSTALLATION_PATH; they do not install a port-based server automatically."
        log_msg INFO "Install a server backend or provide one with --backend-command / LOCAL_AI_NPU_BACKEND_COMMAND."
    else
        log_error "No server backend is configured for model type '$MODEL_TYPE'."
        log_msg INFO "Provide --backend-command with LOCAL_AI_MODEL_* and LOCAL_AI_PORT variables, or point the script at a compatible server binary."
    fi
}

wait_for_service() {
    local wait_port=$1
    local wait_seconds=$2
    local deadline=$((SECONDS + wait_seconds))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if port_in_use "$wait_port"; then
            if command -v curl >/dev/null 2>&1; then
                if curl -fsS --max-time 2 "http://127.0.0.1:${wait_port}/health" >/dev/null 2>&1 \
                    || curl -fsS --max-time 2 "http://127.0.0.1:${wait_port}/v1/models" >/dev/null 2>&1 \
                    || curl -fsS --max-time 2 "http://127.0.0.1:${wait_port}/" >/dev/null 2>&1; then
                    return 0
                fi
            else
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

write_state_files() {
    printf '%s\n' "$PORT" > "$MODEL_DIR/.run_model_port"
    printf '%s\n' "$PID" > "$MODEL_DIR/.run_model_pid"

    {
        printf 'MODEL_NAME=%q\n' "$MODEL_NAME"
        printf 'MODEL_TYPE=%q\n' "$MODEL_TYPE"
        printf 'MODEL_PATH=%q\n' "$MODEL_INPUT"
        printf 'MODEL_DIR=%q\n' "$MODEL_DIR"
        printf 'MODEL_FILE=%q\n' "$MODEL_FILE"
        printf 'PORT=%q\n' "$PORT"
        printf 'PID=%q\n' "$PID"
        printf 'BACKEND=%q\n' "$BACKEND_LABEL"
        printf 'CTX_SIZE=%q\n' "$CTX_SIZE"
        printf 'LOG_FILE=%q\n' "$CURRENT_LOG_FILE"
    } > "$MODEL_DIR/.run_model_last.env"
}

terminate_pid() {
    local target_pid=$1
    local description=$2
    local log_file=${3:-}
    local waited=0

    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        printf '[INFO] %s stopping %s (pid=%s)\n' "$(timestamp_iso)" "$description" "$target_pid" >>"$log_file"
    fi

    if ! kill -0 "$target_pid" 2>/dev/null; then
        remove_registry_pid "$target_pid"
        return 0
    fi

    kill "$target_pid" 2>/dev/null || true
    while kill -0 "$target_pid" 2>/dev/null; do
        if [ "$waited" -ge 10 ]; then
            kill -9 "$target_pid" 2>/dev/null || true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    remove_registry_pid "$target_pid"
}

list_models() {
    prune_registry
    if [ ! -s "$REGISTRY_FILE" ]; then
        printf 'No managed model processes are running.\n'
        return 0
    fi

    while IFS=$'\t' read -r pid port model_name model_type model_path model_dir log_file backend started_at; do
        printf 'PID=%s PORT=%s MODEL=%s TYPE=%s BACKEND=%s STARTED=%s\n' \
            "$pid" "$port" "$model_name" "$model_type" "$backend" "$started_at"
        printf 'PATH=%s\n' "$model_path"
        printf 'DIR=%s\n' "$model_dir"
        printf 'LOG=%s\n' "$log_file"
        printf '\n'
    done < "$REGISTRY_FILE"
}

print_stats() {
    prune_registry

    if get_npu_usage_percent; then
        printf 'NPU usage: %s%% (source: %s)\n' "$NPU_USAGE_VALUE" "$NPU_USAGE_SOURCE"
    else
        printf 'NPU usage: unavailable\n'
    fi

    if [ -n "$RYZEN_AI_RUNTIME_ROOT" ]; then
        printf 'Ryzen AI runtime: %s\n' "$RYZEN_AI_RUNTIME_ROOT"
    fi

    printf '\nManaged models:\n'
    list_models
}

start_model() {
    local raw_path=$1
    local requested_port=$2
    local custom_backend=$3
    local wait_seconds=$4
    local threshold=$5
    local skip_npu_check=$6
    local existing_record=""
    local selected_port=""
    local requested_port_value=$requested_port
    local launch_epoch

    detect_model "$raw_path"
    launch_epoch=$(timestamp_unix)
    build_log_paths "$launch_epoch"

    log_msg INFO 'run_model.sh starting'
    log_msg INFO "Model path: $MODEL_INPUT"
    log_msg INFO "Model type: $MODEL_TYPE"
    log_msg INFO "Model dir: $MODEL_DIR"
    log_msg INFO "Model file: $MODEL_FILE"
    log_msg INFO "Context size: $CTX_SIZE"

    existing_record=$(find_registry_by_model "$MODEL_DIR" || true)
    if [ -n "$existing_record" ]; then
        local existing_pid existing_port existing_name existing_type existing_path existing_dir existing_log existing_backend existing_started
        IFS=$'\t' read -r existing_pid existing_port existing_name existing_type existing_path existing_dir existing_log existing_backend existing_started <<<"$existing_record"
        log_error "Refusing to start duplicate model. Existing process pid=${existing_pid} port=${existing_port}."
        exit 1
    fi

    if [ -z "$requested_port_value" ]; then
        requested_port_value='8080'
    fi
    if ! is_uint "$requested_port_value"; then
        log_error "Invalid port: $requested_port_value"
        exit 1
    fi

    selected_port=$(choose_port "$requested_port_value" || true)
    if [ -z "$selected_port" ]; then
        log_error "No free port found in range ${requested_port_value}..$((requested_port_value + 99))"
        exit 1
    fi
    PORT="$selected_port"

    if [ "$PORT" != "$requested_port_value" ]; then
        log_msg WARN "Requested port $requested_port_value is busy. Using $PORT instead."
    fi
    log_msg INFO "Chosen port: $PORT"

    ensure_npu_capacity "$threshold" "$skip_npu_check"
    configure_ryzen_ai_runtime_environment

    if ! resolve_backend "$custom_backend"; then
        explain_missing_backend
        exit 2
    fi

    log_msg INFO "Backend: $BACKEND_LABEL"
    log_msg INFO "Launch command: $BACKEND_COMMAND"
    log_msg INFO "Logs: $CURRENT_LOG_FILE"

    if command -v setsid >/dev/null 2>&1; then
        env \
            LOCAL_AI_MODEL_PATH="$MODEL_INPUT" \
            LOCAL_AI_MODEL_DIR="$MODEL_DIR" \
            LOCAL_AI_MODEL_FILE="$MODEL_FILE" \
            LOCAL_AI_PORT="$PORT" \
            LOCAL_AI_CTX_SIZE="$CTX_SIZE" \
            LOCAL_AI_LOG_FILE="$CURRENT_LOG_FILE" \
            setsid bash -lc "$BACKEND_COMMAND" >>"$CURRENT_LOG_FILE" 2>&1 < /dev/null &
    else
        env \
            LOCAL_AI_MODEL_PATH="$MODEL_INPUT" \
            LOCAL_AI_MODEL_DIR="$MODEL_DIR" \
            LOCAL_AI_MODEL_FILE="$MODEL_FILE" \
            LOCAL_AI_PORT="$PORT" \
            LOCAL_AI_CTX_SIZE="$CTX_SIZE" \
            LOCAL_AI_LOG_FILE="$CURRENT_LOG_FILE" \
            bash -lc "$BACKEND_COMMAND" >>"$CURRENT_LOG_FILE" 2>&1 < /dev/null &
    fi

    PID=$!
    log_msg INFO "Started backend pid=$PID"
    log_msg INFO "Waiting up to ${wait_seconds}s for port $PORT to become reachable"

    if ! wait_for_service "$PORT" "$wait_seconds"; then
        log_error "Backend did not become reachable on port $PORT within ${wait_seconds}s."
        terminate_pid "$PID" "failed startup" "$CURRENT_LOG_FILE"
        exit 1
    fi

    append_registry_record
    write_state_files

    log_msg INFO "Model is reachable on http://127.0.0.1:$PORT/"
    log_msg INFO "If the backend exposes an OpenAI-compatible API, try http://127.0.0.1:$PORT/v1"
    printf '%s\n' "$PORT"
}

stop_model() {
    local target_pid=''
    local target_port=''
    local target_model=''
    local stop_all=false
    local record=''

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pid)
                target_pid=$2
                shift 2
                ;;
            --port)
                target_port=$2
                shift 2
                ;;
            --model)
                target_model=$2
                shift 2
                ;;
            --all)
                stop_all=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown stop option: %s\n' "$1" >&2
                exit 1
                ;;
        esac
    done

    prune_registry

    if [ "$stop_all" = true ]; then
        if [ ! -s "$REGISTRY_FILE" ]; then
            printf 'No managed model processes are running.\n'
            return 0
        fi
        while IFS=$'\t' read -r pid port model_name model_type model_path model_dir log_file backend started_at; do
            printf 'Stopping pid=%s port=%s model=%s\n' "$pid" "$port" "$model_name"
            terminate_pid "$pid" "$model_name" "$log_file"
        done < "$REGISTRY_FILE"
        prune_registry
        return 0
    fi

    if [ -n "$target_port" ]; then
        if ! is_uint "$target_port"; then
            printf 'Invalid port: %s\n' "$target_port" >&2
            exit 1
        fi
        record=$(find_registry_by_port "$target_port" || true)
    elif [ -n "$target_model" ]; then
        record=$(find_registry_by_model "$(resolve_path "$target_model")" || true)
    elif [ -n "$target_pid" ]; then
        if ! is_uint "$target_pid"; then
            printf 'Invalid pid: %s\n' "$target_pid" >&2
            exit 1
        fi
    else
        printf 'stop requires --pid, --port, --model or --all\n' >&2
        exit 1
    fi

    if [ -n "$record" ]; then
        local record_pid record_port record_name record_type record_path record_dir record_log record_backend record_started
        IFS=$'\t' read -r record_pid record_port record_name record_type record_path record_dir record_log record_backend record_started <<<"$record"
        printf 'Stopping pid=%s port=%s model=%s\n' "$record_pid" "$record_port" "$record_name"
        terminate_pid "$record_pid" "$record_name" "$record_log"
        prune_registry
        return 0
    fi

    if [ -n "$target_pid" ]; then
        if ! kill -0 "$target_pid" 2>/dev/null; then
            printf 'No running process found for pid %s\n' "$target_pid"
            return 0
        fi
        printf 'Stopping unmanaged pid=%s\n' "$target_pid"
        terminate_pid "$target_pid" "unmanaged-process"
        prune_registry
        return 0
    fi

    printf 'No managed model process matched the requested selector.\n'
}

main() {
    local command="${1:-}"
    local requested_port=''
    local custom_backend="${LOCAL_AI_NPU_BACKEND_COMMAND:-}"
    local wait_seconds='60'
    local threshold='70'
    local skip_npu_check=false
    local model_path=''

    ensure_runtime_dir

    case "$command" in
        ''|-h|--help|help)
            usage
            exit 0
            ;;
        list|status)
            shift
            list_models
            exit 0
            ;;
        stats)
            shift
            configure_ryzen_ai_runtime_environment
            print_stats
            exit 0
            ;;
        stop)
            shift
            stop_model "$@"
            exit 0
            ;;
        start)
            shift
            ;;
        *)
            command='start'
            ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --port)
                requested_port=$2
                shift 2
                ;;
            --wait-seconds)
                wait_seconds=$2
                shift 2
                ;;
            --backend-command)
                custom_backend=$2
                shift 2
                ;;
            --npu-usage-threshold)
                threshold=$2
                shift 2
                ;;
            --skip-npu-usage-check)
                skip_npu_check=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                printf 'Unknown option: %s\n' "$1" >&2
                exit 1
                ;;
            *)
                if [ -z "$model_path" ]; then
                    model_path=$1
                    shift
                elif [ -z "$requested_port" ] && is_uint "$1"; then
                    requested_port=$1
                    shift
                else
                    printf 'Unexpected argument: %s\n' "$1" >&2
                    exit 1
                fi
                ;;
        esac
    done

    if [ -z "$model_path" ]; then
        usage
        exit 1
    fi

    if ! is_uint "$wait_seconds"; then
        printf 'Invalid wait-seconds value: %s\n' "$wait_seconds" >&2
        exit 1
    fi
    if ! is_uint "$threshold"; then
        printf 'Invalid npu-usage-threshold value: %s\n' "$threshold" >&2
        exit 1
    fi

    start_model "$model_path" "$requested_port" "$custom_backend" "$wait_seconds" "$threshold" "$skip_npu_check"
}

main "$@"

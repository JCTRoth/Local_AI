#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$SCRIPT_DIR/.python-packages"
DEFAULT_RYZEN_AI_ROOT="/opt/ryzen_ai"
if [ -z "${RYZEN_AI_ROOT:-}" ] && [ -d "$HOME/ryzen_ai_env" ]; then
    DEFAULT_RYZEN_AI_ROOT="$HOME/ryzen_ai_env"
fi
RYZEN_AI_ROOT="${RYZEN_AI_ROOT:-$DEFAULT_RYZEN_AI_ROOT}"
PYTHON_BIN="${PYTHON_BIN:-$RYZEN_AI_ROOT/bin/python}"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements-openai-server.txt"

if [ ! -x "$PYTHON_BIN" ]; then
    printf 'Python interpreter not found: %s\n' "$PYTHON_BIN" >&2
    exit 1
fi

if [ ! -f "$REQUIREMENTS_FILE" ]; then
    printf 'Requirements file not found: %s\n' "$REQUIREMENTS_FILE" >&2
    exit 1
fi

rm -rf "$SITE_DIR"
mkdir -p "$SITE_DIR"

"$PYTHON_BIN" -m pip install --upgrade pip >/dev/null
"$PYTHON_BIN" -m pip install --target "$SITE_DIR" -r "$REQUIREMENTS_FILE"

printf 'Installed dependencies into %s\n' "$SITE_DIR"
printf 'Use %s to start the server.\n' "$SCRIPT_DIR/run_openai_npu_server.sh"
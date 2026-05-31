#!/usr/bin/env bash
# =============================================================================
# MCP Server Install Script for VS Code + GitHub Copilot
# Installs only MCP client prerequisites and copies workspace config files.
# Supports: macOS, Fedora, Ubuntu/Debian
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT_DEFAULT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="${MCP_WORKSPACE_ROOT:-${WORKSPACE_ROOT_DEFAULT}}"
MCP_SOURCE="${SCRIPT_DIR}/mcp.json"
TOOLS_SOURCE="${SCRIPT_DIR}/tools.yaml"
MCP_TARGET="${WORKSPACE_ROOT}/.vscode/mcp.json"
TOOLS_TARGET="${WORKSPACE_ROOT}/tools.yaml"
DRY_RUN=0

print_header() {
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}"
}

print_success() { echo -e "${GREEN}[ok] $1${NC}"; }
print_warn() { echo -e "${YELLOW}[warn] $1${NC}"; }
print_error() { echo -e "${RED}[error] $1${NC}"; }
print_info() { echo -e "${BLUE}[info] $1${NC}"; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
Usage: ./mcpServers-copilot/install.sh [--dry-run]

Installs only MCP client prerequisites, then copies this kit's mcp.json into
${WORKSPACE_ROOT}/.vscode/mcp.json and tools.yaml into ${WORKSPACE_ROOT}/tools.yaml.

Environment overrides:
  MCP_WORKSPACE_ROOT=/path/to/workspace
EOF
}

run_cmd() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '+ %q' "$1"
    shift
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

copy_file() {
  local src="$1"
  local dest="$2"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '+ install -Dm644 %q %q\n' "$src" "$dest"
  else
    install -Dm644 "$src" "$dest"
  fi
}

backup_file() {
  local path="$1"
  local backup="${path}.bak.$(date +%Y%m%d%H%M%S)"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '+ cp %q %q\n' "$path" "$backup"
  else
    cp "$path" "$backup"
  fi

  printf '%s\n' "$backup"
}

require_kit_files() {
  if [[ ! -f "${MCP_SOURCE}" ]]; then
    print_error "Missing kit file: ${MCP_SOURCE}"
    exit 1
  fi

  if [[ ! -f "${TOOLS_SOURCE}" ]]; then
    print_error "Missing kit file: ${TOOLS_SOURCE}"
    exit 1
  fi
}

detect_os() {
  if [[ "${OSTYPE}" == linux-gnu* ]]; then
    if [[ -f /etc/fedora-release ]]; then
      echo "fedora"
    elif [[ -f /etc/os-release ]]; then
      local id_like
      id_like="$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')"
      local id
      id="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
      if [[ "${id}" == "ubuntu" ]] || [[ "${id}" == "debian" ]] || [[ "${id_like}" == *debian* ]] || [[ "${id_like}" == *ubuntu* ]]; then
        echo "ubuntu"
      else
        echo "linux"
      fi
    else
      echo "linux"
    fi
  elif [[ "${OSTYPE}" == darwin* ]]; then
    echo "macos"
  else
    echo "unknown"
  fi
}

install_node() {
  print_header "Step 1/4: Installing Node.js 20+"

  if command_exists node && [[ "$(node -v | cut -d'v' -f2 | cut -d'.' -f1)" -ge 20 ]]; then
    print_success "Node.js $(node -v) already installed"
    return 0
  fi

  case "${OS}" in
    fedora)
      print_warn "Installing Node.js via NodeSource RPM..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "+ curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -"
        echo "+ sudo dnf install -y nodejs"
      else
        curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
        sudo dnf install -y nodejs
      fi
      ;;
    ubuntu)
      print_warn "Installing Node.js via NodeSource DEB..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "+ sudo apt-get update"
        echo "+ sudo apt-get install -y ca-certificates curl gnupg"
        echo "+ curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -"
        echo "+ sudo apt-get install -y nodejs"
      else
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl gnupg
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
        sudo apt-get install -y nodejs
      fi
      ;;
    macos)
      if command_exists brew; then
        print_warn "Installing Node.js via Homebrew..."
        run_cmd brew install node
      else
        print_error "Homebrew is required on macOS. Install it from https://brew.sh"
        exit 1
      fi
      ;;
    linux)
      print_error "Unsupported Linux distribution for automated Node.js installation."
      print_info "Install Node.js 20+ manually and rerun the script."
      exit 1
      ;;
  esac

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    print_success "Node.js $(node -v) installed"
  fi
}

install_vscode() {
  print_header "Step 2/4: Installing Visual Studio Code"

  if command_exists code; then
    print_success "VS Code already installed ($(code --version | head -n1))"
    return 0
  fi

  case "${OS}" in
    fedora)
      print_warn "Adding Microsoft VS Code RPM repository..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "+ sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc"
        echo "+ sudo sh -c 'echo -e \"[code]\\nname=Visual Studio Code\\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\\nenabled=1\\ngpgcheck=1\\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\" > /etc/yum.repos.d/vscode.repo'"
        echo "+ sudo dnf check-update || true"
        echo "+ sudo dnf install -y code"
      else
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
        sudo dnf check-update || true
        sudo dnf install -y code
      fi
      ;;
    ubuntu)
      print_warn "Adding Microsoft VS Code APT repository..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "+ sudo apt-get update"
        echo "+ sudo apt-get install -y wget gpg apt-transport-https"
        echo "+ wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg"
        echo "+ sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg"
        echo "+ sudo sh -c 'echo \"deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main\" > /etc/apt/sources.list.d/vscode.list'"
        echo "+ rm -f packages.microsoft.gpg"
        echo "+ sudo apt-get update"
        echo "+ sudo apt-get install -y code"
      else
        sudo apt-get update
        sudo apt-get install -y wget gpg apt-transport-https
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
        sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
        sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
        rm -f packages.microsoft.gpg
        sudo apt-get update
        sudo apt-get install -y code
      fi
      ;;
    macos)
      if command_exists brew; then
        print_warn "Installing VS Code via Homebrew..."
        run_cmd brew install --cask visual-studio-code
      else
        print_error "Homebrew is required on macOS. Install it from https://brew.sh"
        exit 1
      fi
      ;;
    linux)
      print_error "Unsupported Linux distribution for automated VS Code installation."
      print_info "Install VS Code manually and rerun the script."
      exit 1
      ;;
  esac

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    print_success "VS Code installed"
  fi
}

install_copilot() {
  print_header "Step 3/4: Installing GitHub Copilot Extensions"

  if ! command_exists code; then
    print_error "VS Code 'code' CLI not found. Cannot install extensions."
    return 1
  fi

  print_warn "Installing GitHub Copilot extensions..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "+ code --install-extension GitHub.copilot"
    echo "+ code --install-extension GitHub.copilot-chat"
  else
    code --install-extension GitHub.copilot || true
    code --install-extension GitHub.copilot-chat || true
  fi

  print_success "GitHub Copilot extensions installed"
}

create_configs() {
  local backup

  print_header "Step 4/4: Creating Workspace MCP Configuration"

  if [[ -f "${MCP_TARGET}" ]] && cmp -s "${MCP_SOURCE}" "${MCP_TARGET}"; then
    print_success "Workspace MCP config already matches the kit"
  else
    if [[ -f "${MCP_TARGET}" ]]; then
      backup="$(backup_file "${MCP_TARGET}")"
      print_warn "Backed up existing mcp.json to ${backup}"
    fi

    copy_file "${MCP_SOURCE}" "${MCP_TARGET}"
    print_success "Installed ${MCP_TARGET}"
  fi

  if [[ -f "${TOOLS_TARGET}" ]]; then
    if cmp -s "${TOOLS_SOURCE}" "${TOOLS_TARGET}"; then
      print_success "Workspace tools.yaml already matches the kit"
    else
      print_warn "Keeping existing ${TOOLS_TARGET} to avoid overwriting credentials"
      print_info "Compare it with ${TOOLS_SOURCE} if you want the latest template updates."
    fi
  else
    copy_file "${TOOLS_SOURCE}" "${TOOLS_TARGET}"
    print_success "Installed ${TOOLS_TARGET}"
  fi
}

check_prerequisites() {
  print_header "Prerequisite Checks (Manual Installation Required)"

  if command_exists docker; then
    print_success "Docker CLI detected"
  else
    print_warn "Docker CLI not found. The docker-mcp server will not work."
    print_info "Install Docker Desktop or Docker Engine, then enable the Docker MCP Toolkit if needed."
  fi

  if command_exists kubectl; then
    print_success "kubectl detected"
    if [[ -f "${HOME}/.kube/config" ]]; then
      print_success "Kubeconfig found at ~/.kube/config"
    else
      print_warn "Kubeconfig not found at ~/.kube/config"
      print_info "The Kubernetes MCP server requires a valid kubeconfig."
      print_info "Run: kubectl config view"
    fi
  else
    print_warn "kubectl not found. The kubernetes server will not work."
    print_info "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
  fi

  if command_exists google-chrome || command_exists chromium || command_exists chromium-browser; then
    print_success "Chrome or Chromium detected"
  else
    print_warn "Chrome or Chromium not found. The chrome-devtools server requires a running browser."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        print_error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  require_kit_files
  OS="$(detect_os)"

  print_header "MCP Server Setup for VS Code + Copilot"
  print_info "Kit source: ${SCRIPT_DIR}"
  print_info "Workspace root: ${WORKSPACE_ROOT}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    print_info "Dry run enabled: commands will be printed but not executed."
  fi
  echo ""
  print_info "This script installs only the MCP client-side prerequisites."
  print_info "It does not install Docker, Kubernetes, Chrome, or databases."
  echo ""

  if [[ "${OS}" == "unknown" ]]; then
    print_error "Unsupported operating system. Exiting."
    exit 1
  fi

  install_node
  install_vscode
  install_copilot
  create_configs
  check_prerequisites

  print_header "Setup Complete"
  echo ""
  echo -e "${GREEN}Next steps:${NC}"
  echo "  1. Restart VS Code fully if this was a real install run."
  echo "  2. Open Copilot Chat and switch to Agent mode."
  echo "  3. Start the servers from ${MCP_TARGET}."
  echo "  4. Edit ${TOOLS_TARGET} with your database credentials if you plan to use Google Toolbox."
  echo ""
  print_warn "Chrome must be running before using Chrome DevTools MCP."
  print_warn "Docker MCP requires Docker support on your machine."
  print_warn "Kubernetes MCP requires kubectl and a valid kubeconfig."
}

main "$@"
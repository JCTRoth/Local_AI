#!/usr/bin/env bash

# terminate_model_service.sh
# A robust script to identify and terminate running model services by address and port.

set -euo pipefail
IFS=$'\n\t'

# Color definitions using tput
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
BOLD=$(tput bold)
RESET=$(tput sgr0)

# Default values
ADDRESS="127.0.0.1"
PORT=""
SKIP_CONFIRM=false
LOG_FILE=""
LOG_LEVEL="INFO"

# Usage function
usage() {
  cat <<'EOF'
Usage: terminate_model_service.sh [options]

Options:
  --address ADDRESS  Address to check (default: 127.0.0.1)
  --port PORT        Port to check (required)
  -y, --yes          Skip confirmation prompts
  --log FILE         Log actions to a file
  --log-level LEVEL  Log level (INFO, WARN, ERROR, DEBUG) (default: INFO)
  -h, --help         Show this help message

Examples:
  ./terminate_model_service.sh --address 127.0.0.1 --port 8080
  ./terminate_model_service.sh -y --port 5000
  ./terminate_model_service.sh --port 8080 --log-level DEBUG
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --address)
      ADDRESS="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    -y|--yes)
      SKIP_CONFIRM=true
      shift
      ;;
    --log)
      LOG_FILE="$2"
      shift 2
      ;;
    --log-level)
      LOG_LEVEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "${RED}Error: Unknown option $1${RESET}" >&2
      usage
      exit 1
      ;;
  esac
done

# Validate port
if [[ -z "$PORT" ]]; then
  log "${RED}Error: Port is required. Use --port to specify.${RESET}"
  usage
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
  log "${RED}Error: Invalid port number. Port must be between 1 and 65535.${RESET}"
  exit 1
fi

# Validate address
if ! [[ "$ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ "$ADDRESS" != "localhost" ]]; then
  log "${RED}Error: Invalid address. Use an IP address or 'localhost'.${RESET}"
  exit 1
fi

# Check if port is privileged
if [[ "$PORT" -lt 1024 ]] && [[ "$(id -u)" -ne 0 ]]; then
  log "${YELLOW}Warning: Port $PORT is privileged. You may need sudo to terminate processes.${RESET}"
fi

# Function to log messages
log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  
  # Check log level
  case "$level" in
    DEBUG)
      if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
        echo "[$timestamp] [DEBUG] $message" | tee -a "${LOG_FILE:-/dev/stderr}"
      fi
      ;;
    INFO)
      if [[ "$LOG_LEVEL" == "DEBUG" || "$LOG_LEVEL" == "INFO" ]]; then
        echo "[$timestamp] [INFO] $message" | tee -a "${LOG_FILE:-/dev/stderr}"
      fi
      ;;
    WARN)
      if [[ "$LOG_LEVEL" == "DEBUG" || "$LOG_LEVEL" == "INFO" || "$LOG_LEVEL" == "WARN" ]]; then
        echo "[$timestamp] [WARN] $message" | tee -a "${LOG_FILE:-/dev/stderr}"
      fi
      ;;
    ERROR)
      echo "[$timestamp] [ERROR] $message" | tee -a "${LOG_FILE:-/dev/stderr}"
      ;;
    *)
      echo "[$timestamp] [INFO] $message" | tee -a "${LOG_FILE:-/dev/stderr}"
      ;;
  esac
}

# Function to detect processes using the port
detect_processes() {
  local port="$1"
  local processes=()
  
  # Try lsof first
  if command -v lsof >/dev/null 2>&1; then
    log "INFO" "Using lsof to detect processes on port $port..."
    while IFS= read -r line; do
      processes+=("$line")
    done < <(lsof -i :"$port" 2>/dev/null || true)
  # Fallback to ss
  elif command -v ss >/dev/null 2>&1; then
    log "INFO" "Using ss to detect processes on port $port..."
    while IFS= read -r line; do
      processes+=("$line")
    done < <(ss -tulnp "sport = :$port" 2>/dev/null || true)
  # Fallback to netstat
  elif command -v netstat >/dev/null 2>&1; then
    log "INFO" "Using netstat to detect processes on port $port..."
    while IFS= read -r line; do
      processes+=("$line")
    done < <(netstat -tulnp | grep ":$port" 2>/dev/null || true)
  else
    log "ERROR" "${RED}Error: No suitable tool (lsof, ss, netstat) found to detect processes.${RESET}"
    exit 1
  fi
  
  if [[ ${#processes[@]} -eq 0 ]]; then
    log "DEBUG" "No processes found on port $port"
  else
    log "DEBUG" "Found ${#processes[@]} process(es) on port $port"
  fi
  
  echo "${processes[@]}"
}

# Function to extract PID from process info
extract_pids() {
  local processes=("$@")
  local pids=()
  
  for line in "${processes[@]}"; do
    if [[ "$line" =~ [0-9]+ ]]; then
      # Extract PID using awk
      pid=$(echo "$line" | awk '{print $2}' 2>/dev/null || echo "")
      if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
        pids+=("$pid")
        log "DEBUG" "Extracted PID: $pid from line: $line"
      fi
    fi
  done
  
  if [[ ${#pids[@]} -eq 0 ]]; then
    log "WARN" "No valid PIDs found in process list"
  else
    log "INFO" "Found ${#pids[@]} valid PID(s)"
  fi
  
  echo "${pids[@]}"
}

# Function to get detailed process info
get_process_info() {
  local pid="$1"
  local info=""
  
  if [[ -d "/proc/$pid" ]]; then
    info="PID: $pid"
    info="$info\nUser: $(ps -o user= -p "$pid" 2>/dev/null || echo "N/A")"
    info="$info\nProcess Name: $(ps -o comm= -p "$pid" 2>/dev/null || echo "N/A")"
    info="$info\nCommand: $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "N/A")"
    info="$info\nStart Time: $(ps -o lstart= -p "$pid" 2>/dev/null || echo "N/A")"
    info="$info\nCPU/Memory: $(ps -o %cpu,%mem= -p "$pid" 2>/dev/null || echo "N/A")"
    log "DEBUG" "Retrieved info for PID $pid"
  else
    info="PID: $pid (not found)"
    log "WARN" "Process $pid not found in /proc"
  fi
  
  echo "$info"
}

# Function to check if process is a container
is_container() {
  local pid="$1"
  local cgroup=""
  
  if [[ -f "/proc/$pid/cgroup" ]]; then
    cgroup=$(cat "/proc/$pid/cgroup" 2>/dev/null | grep -E "docker|podman" || true)
    if [[ -n "$cgroup" ]]; then
      log "DEBUG" "Process $pid is running in a container (cgroup: $cgroup)"
      return 0
    fi
  fi
  
  log "DEBUG" "Process $pid is not running in a container"
  return 1
}

# Function to check for child processes
has_children() {
  local pid="$1"
  local children=""
  
  children=$(pgrep -P "$pid" 2>/dev/null || true)
  if [[ -n "$children" ]]; then
    log "DEBUG" "Process $pid has child processes: $children"
    return 0
  fi
  
  log "DEBUG" "Process $pid has no child processes"
  return 1
}

# Function to terminate processes
terminate_processes() {
  local pids=("$@")
  local success=true
  
  for pid in "${pids[@]}"; do
    if [[ -d "/proc/$pid" ]]; then
      log "INFO" "Terminating process $pid..."
      
      # Send SIGTERM
      if kill -TERM "$pid" 2>/dev/null; then
        log "INFO" "Sent SIGTERM to process $pid"
        
        # Wait for process to terminate
        local wait_time=0
        while [[ -d "/proc/$pid" ]] && [[ "$wait_time" -lt 5 ]]; do
          sleep 1
          wait_time=$((wait_time + 1))
        done
        
        # Check if process is still running
        if [[ -d "/proc/$pid" ]]; then
          log "WARN" "Process $pid did not terminate gracefully. Sending SIGKILL..."
          if kill -KILL "$pid" 2>/dev/null; then
            log "INFO" "Sent SIGKILL to process $pid"
            
            # Wait a bit more for SIGKILL to take effect
            sleep 1
            if [[ -d "/proc/$pid" ]]; then
              log "ERROR" "Process $pid still running after SIGKILL"
              success=false
            fi
          else
            log "ERROR" "${RED}Failed to send SIGKILL to process $pid${RESET}"
            success=false
          fi
        fi
      else
        log "ERROR" "${RED}Failed to send SIGTERM to process $pid${RESET}"
        success=false
      fi
    else
      log "WARN" "Process $pid not found"
    fi
  done
  
  if [[ "$success" == true ]]; then
    log "INFO" "${GREEN}All processes terminated successfully.${RESET}"
    return 0
  else
    log "ERROR" "${RED}Some processes failed to terminate.${RESET}"
    return 1
  fi
}

# Main script logic
main() {
  local processes
  local pids
  local confirm=""
  
  log "INFO" "Checking for processes on $ADDRESS:$PORT..."
  
  # Detect processes
  processes=$(detect_processes "$PORT")
  
  if [[ -z "$processes" ]]; then
    log "WARN" "${YELLOW}No processes found on port $PORT.${RESET}"
    exit 1
  fi
  
  # Extract PIDs
  pids=$(extract_pids $processes)
  
  if [[ -z "$pids" ]]; then
    log "WARN" "${YELLOW}No valid PIDs found.${RESET}"
    exit 1
  fi
  
  log "INFO" "Found processes on port $PORT:"
  
  # Display process info
  for pid in $pids; do
    echo ""
    echo "${BLUE}=== Process $pid ===${RESET}"
    get_process_info "$pid"
    
    # Check if process is a container
    if is_container "$pid"; then
      echo "${YELLOW}Warning: This process is running in a container. Consider using 'docker stop' or 'podman stop' instead.${RESET}"
    fi
    
    # Check for child processes
    if has_children "$pid"; then
      echo "${YELLOW}Warning: This process has child processes.${RESET}"
    fi
  done
  
  # Confirm termination
  if [[ "$SKIP_CONFIRM" == false ]]; then
    read -p "${BOLD}Terminate these processes? (y/N): ${RESET}" confirm
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$confirm" != "y" ]]; then
      log "INFO" "${GREEN}Termination cancelled.${RESET}"
      exit 3
    fi
  fi
  
  # Terminate processes
  log "INFO" "Attempting to terminate processes..."
  if terminate_processes $pids; then
    log "INFO" "Termination completed successfully"
    exit 0
  else
    log "ERROR" "Termination completed with errors"
    exit 1
  fi
}

# Run main function
main
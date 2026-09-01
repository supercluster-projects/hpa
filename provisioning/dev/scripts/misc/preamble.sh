# preamble.sh — shared bootstrapping for all provisioning scripts
# Source at the top of every script (after the header comment block):
#   . ../misc/preamble.sh
#
# Provides:
#   SCRIPT_DIR         — absolute path to provisioning/dev/scripts/
#   PROJECT_ROOT       — absolute path to the worktree/project root
#   KUBECONFIG         — default kubeconfig path (overridable via env or --kubeconfig)
#   log()              — timestamped stderr to startup.log only (fd 1/2 tee)
#   err()              — ERROR-prefixed log
#   die()              — error log + final red message on fd 3 + exit 1
#   require_env()      — fail with clear message if env var is not set
#   check_internet()   — check if internet is reachable (DNS + HTTP)
#   wait_for_internet() — poll until internet comes back, 10s interval
#   step_start()       — mark start of a pipeline step
#   step_end()         — mark end of a pipeline step with status
#   START_TIME         — epoch seconds for duration computation

set -euo pipefail

# SCRIPT_DIR is the parent directory of misc/ (i.e., provisioning/dev/scripts/)
# BASH_SOURCE[0] is always the preamble.sh file (in misc/)
_PREAMBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# SCRIPT_DIR should always be the scripts/ directory (parent of misc/)
SCRIPT_DIR="$(cd "${_PREAMBLE_DIR}/.." && pwd)"

# Common script directories
MISC_DIR="${SCRIPT_DIR}/misc"

# Directory structure: project_root/provisioning/dev/scripts/{misc,steps/step-XX/}
# From misc: misc -> scripts -> dev -> provisioning -> project_root (4 levels up)
# From steps: steps/step-XX -> steps -> scripts -> dev -> provisioning -> project_root (5 levels up)
if [[ "${SCRIPT_DIR}" == */steps/* ]]; then
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
else
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi

KUBECONFIG="${KUBECONFIG:-${PROJECT_ROOT}/provisioning/dev/opentofu/kubeconfig}"
STARTUP_LOG="${PROJECT_ROOT}/provisioning/dev/startup.log"
START_TIME=$(date +%s)

# ---- Log setup: capture all output to startup.log at project root --------
# Save fd 3 to the raw terminal BEFORE the tee redirect, so that the
# bootstrap monitor and progress table can write updating lines that
# overwrite each other on screen without accumulating in startup.log.
exec 3>&2

# Clear the log file at the start of each run so stale output is not confusing.
: > "${STARTUP_LOG}" 2>/dev/null || true
exec > >(tee -a "${STARTUP_LOG}" 2>/dev/null) 2>&1 || exec > /dev/null
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Logging all output to ${STARTUP_LOG}"

# ---- Log helpers ----------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_step() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${STARTUP_LOG}" 2>/dev/null || true; }
log_step_update() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '\r\033[K[%s] %s\n' "${ts}" "$*" | tee -a "${STARTUP_LOG}" 2>/dev/null || true
}
err()  { log "ERROR: $*"; }
die()  {
  local msg="$*"
  err "$msg"
  printf "\n\e[1;31m✖ FATAL: %s\e[0m\n" "$msg" >&3 2>/dev/null || true
  exit 1
}

# ---- Step tracking helpers (replaces table system) ---------------------------
_STEP_COUNTER=0
STEP_START() {
  local step_name="$1"
  _STEP_COUNTER=$((_STEP_COUNTER + 1))
  echo ""
  log "========================================"
  log "Step ${_STEP_COUNTER}: ${step_name}"
  log "========================================"
}
STEP_END() {
  local status="$1"
  local detail="${2:-}"
  local elapsed=$(( $(date +%s) - START_TIME ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  case "$status" in
    DONE)
      log "✓ Step ${_STEP_COUNTER} completed in ${mins}m ${secs}s"
      ;;
    SKIPPED)
      log "○ Step ${_STEP_COUNTER} skipped${detail:+: ${detail}}"
      ;;
    FAIL|FAILED)
      log "✗ Step ${_STEP_COUNTER} FAILED: ${detail:-unknown error}"
      ;;
    *)
      log "○ Step ${_STEP_COUNTER} ${status}"
      ;;
  esac
  log ""
}

# ---- Interactive prompt function ----
trim_prompt_input() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_choice() {
  local timeout="${PROMPT_TIMEOUT_SECONDS:-0}"
  local prompt_text="$1"
  local choice=""

  if ! [[ "${timeout}" =~ ^[0-9]+$ ]]; then
    timeout=10
  fi

  if [ "${timeout}" -gt 0 ]; then
    if ! read -r -t "${timeout}" -p "${prompt_text}" choice; then
      echo "" >&3
      return 124
    fi
  else
    if ! read -r -p "${prompt_text}" choice; then
      choice=""
    fi
  fi

  choice="$(trim_prompt_input "${choice}")"
  printf '%s' "$choice"
}

sudo_password() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    return 0
  fi

  if [ "${SUDO_PASSWORD_PROMPTED:-0}" = "1" ]; then
    die "SUDO_PASSWORD is not set and sudo password prompt was already shown"
  fi

  printf '\n' >&3
  read -r -s -p "Enter sudo password: " SUDO_PASSWORD
  printf '\n' >&3
  SUDO_PASSWORD_PROMPTED=1

  [ -n "${SUDO_PASSWORD:-}" ] || die "SUDO_PASSWORD is required for sudo operations. Set it in .env or enter it when prompted."
}

run_as_root() {
  command -v sudo >/dev/null 2>&1 || die "sudo command not found"

  if sudo -n true &>/dev/null; then
    sudo "$@"
    return $?
  fi

  sudo_password
  if ! printf '%s\n' "${SUDO_PASSWORD}" | sudo -S "$@"; then
    err "sudo command failed; check SUDO_PASSWORD or enter a valid password"
    return 1
  fi
}

prompt_step() {
  local step_num=$1
  local step_name=$2
  local result=$3
  local timeout="${PROMPT_TIMEOUT_SECONDS:-0}"
  local max_invalid="${PROMPT_MAX_INVALID_ATTEMPTS:-3}"
  local attempt=0
  local choice=""
  local prompt_text=""
  local choice_file=""
  local status_file=""
  local read_status=0

  if ! [[ "${timeout}" =~ ^[0-9]+$ ]]; then
    timeout=10
  fi

  echo "" >&3
  echo "========================================" >&3
  echo "Step ${step_num}: ${step_name}" >&3
  echo "  Status: ${result}" >&3
  echo "========================================" >&3

  if [ "$result" = "SUCCESS" ]; then
    echo "" >&3
    echo ">>> Verification Results:" >&3
    # Show step-specific verification info
    case "${step_num}" in
      1|2)
        echo "     Network: hpa-bridge (name: ${DEV_BRIDGE_NAME:-hpa-bridge})" >&3
        virsh -c qemu:///system net-info "${DEV_BRIDGE_NAME:-hpa-bridge}" 2>/dev/null | grep "Active:" | head -1 | sed 's/^/     /' >&3 || echo "     Active: verified" >&3
        echo "     Bridge CIDR: ${DEV_CIDR_BLOCK:-192.168.122.0/24}" >&3
        ;;
    esac
    if [ -n "${NODE_COUNT:-}" ]; then
      echo "     Nodes ready: ${NODE_COUNT}" >&3
    fi
    echo "" >&3
    echo "========================================" >&3
    echo "  OPTIONS:" >&3
    echo "    E/e  - Execute next step" >&3
    echo "    S/s  - Skip next step" >&3
    echo "    R/r  - View recent results table" >&3
    echo "    Q/q  - Quit script" >&3
    echo "========================================" >&3

    while true; do
      prompt_text="Choose (E Execute/S Skip/R Results/Q Quit): "
      choice_file="$(mktemp "${TMPDIR:-/tmp}/hpa-prompt-choice.XXXXXX")"
      status_file="$(mktemp "${TMPDIR:-/tmp}/hpa-prompt-status.XXXXXX")"
      if read_choice "${prompt_text}" >"${choice_file}" 2>"${status_file}"; then
        read_status=0
      else
        read_status=$?
      fi
      choice="$(cat "${choice_file}")"
      rm -f "${choice_file}" "${status_file}"

      if [ "${read_status}" -eq 124 ]; then
        if [ "$result" = "SUCCESS" ]; then
          echo "No input received within ${timeout}s; defaulting to Execute next step." >&3
          return 0
        fi
        echo "No input received within ${timeout}s; defaulting to Quit." >&3
        die "Step ${step_num} failed, user requested quit"
      fi

      case "$choice" in
        [Ee])  return 0 ;;
        [Ss])  return 1 ;;
        [Rr])  show_results_table; attempt=0; continue ;;
        [Qq])  die "User requested quit" ;;
        "")    if [ "$result" = "SUCCESS" ]; then
          echo "Empty choice; defaulting to Execute next step." >&3
          return 0
        fi
        echo "Empty choice; defaulting to Quit." >&3
        die "Step ${step_num} failed, user requested quit" ;;
        *)     attempt=$((attempt + 1))
               if [ "${attempt}" -ge "${max_invalid}" ]; then
                 die "Too many invalid choices; exiting"
               fi
               echo "Invalid choice. Please enter E, S, R, or Q." >&3 ;;
      esac
    done
  else
    echo "" >&3
    echo ">>> Step ${step_num}: ${step_name} - FAILED!" >&3
    echo "========================================" >&3
    echo "  OPTIONS:" >&3
    echo "    R/r  - View recent results table" >&3
    echo "    Q/q  - Quit script" >&3
    echo "========================================" >&3

    while true; do
      prompt_text="Choose (R Results/Q Quit): "
      choice_file="$(mktemp "${TMPDIR:-/tmp}/hpa-prompt-choice.XXXXXX")"
      status_file="$(mktemp "${TMPDIR:-/tmp}/hpa-prompt-status.XXXXXX")"
      if read_choice "${prompt_text}" >"${choice_file}" 2>"${status_file}"; then
        read_status=0
      else
        read_status=$?
      fi
      choice="$(cat "${choice_file}")"
      rm -f "${choice_file}" "${status_file}"

      if [ "${read_status}" -eq 124 ]; then
        echo "No input received within ${timeout}s; defaulting to Quit." >&3
        die "Step ${step_num} failed, user requested quit"
      fi

      case "$choice" in
        [Rr])  show_results_table; attempt=0; continue ;;
        [Qq])  die "Step ${step_num} failed, user requested quit" ;;
        "")    echo "Empty choice; defaulting to Quit." >&3
               die "Step ${step_num} failed, user requested quit" ;;
        *)     attempt=$((attempt + 1))
               if [ "${attempt}" -ge "${max_invalid}" ]; then
                 die "Too many invalid choices; exiting"
               fi
               echo "Invalid choice. Please enter R or Q." >&3 ;;
      esac
    done
  fi
}


show_results_table() {
  echo "" >&3
  echo "========================================" >&3
  echo "        STEP RESULTS SUMMARY" >&3
  echo "========================================" >&3
  echo "" >&3
  echo "  Step | Name                              | Status  | Details" >&3
  echo "  -----|-----------------------------------|---------|-------" >&3
  
  local idx=1
  for result in "${STEP_RESULTS[@]}"; do
    echo "$result" >&3
    idx=$((idx + 1))
  done
  
  echo "" >&3
  echo "========================================" >&3
}

# ---- Internet connectivity helpers ----------------------------------------
INTERNET_CHECK_HOSTS="google.com 1.1.1.1 8.8.8.8"
INTERNET_CHECK_URL="https://google.com/generate_204"

check_internet() {
  local host=""
  for host in ${INTERNET_CHECK_HOSTS}; do
    if timeout 3 nslookup "${host}" 2>/dev/null | grep -q "Address"; then
      if timeout 5 curl -sI "${INTERNET_CHECK_URL}" 2>/dev/null | grep -qE "HTTP/[0-9.]+ 20[0-9]"; then
        return 0
      fi
    fi
  done
  for host in ${INTERNET_CHECK_HOSTS}; do
    if timeout 3 bash -c "echo > /dev/tcp/${host}/443" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

wait_for_internet() {
  local label="${1:-network}"
  local poll_count=0
  log "Waiting for internet connection (required for: ${label})..."
  while ! check_internet; do
    poll_count=$((poll_count + 1))
    sleep 10
  done
  log "Internet connectivity restored."
}

# ---- Environment helpers ---------------------------------------------------
require_env() {
  local var_name="$1"
  case "${var_name}" in
    TF_VAR_*) return 0 ;;
  esac
  if [ -z "${!var_name:-}" ]; then
    die "Required environment variable ${var_name} is not set.
  Set it in the .env file (copied from .env.example) or export it before running.
  See .env.example for all required variables."
  fi
}

ENV_FILE="${PROJECT_ROOT}/.env"

# ---- Common Environment Defaults (avoid DRY violations) ----
# These provide sensible defaults that can be overridden by .env

# Network Configuration
CIDR_BASE="${CIDR_BASE:-192.168.122}"
CIDR_BLOCK="${CIDR_BLOCK:-${CIDR_BASE}.0/24}"
GATEWAY_IP="${GATEWAY_IP:-${CIDR_BASE}.1}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-${CIDR_BASE}.100}"

# Kubeconfig path
KUBECONFIG="${KUBECONFIG:-${PROJECT_ROOT}/provisioning/dev/opentofu/kubeconfig}"

# Source .env if it exists (overrides defaults above)
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

command -v kubectl >/dev/null 2>&1 || log "  Warning: kubectl not found in PATH"
command -v helm >/dev/null 2>&1 || log "  Warning: helm not found in PATH"

export KUBECONFIG PROJECT_ROOT CIDR_BASE CIDR_BLOCK GATEWAY_IP CONTROL_PLANE_IP STARTUP_LOG
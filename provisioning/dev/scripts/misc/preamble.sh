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
#
# Progress display: Uses sequential step logs instead of visual table.
# Each step is logged with STARTED/DONE/FAILED status for clarity.

set -euo pipefail

# SCRIPT_DIR is the directory containing the calling script (via BASH_SOURCE)
# When sourced by startup.sh (in scripts/), SCRIPT_DIR should be scripts/
# When sourced by misc/ or steps/, SCRIPT_DIR should be misc/ or steps/xxx/
PARENT_SCRIPT="${BASH_SOURCE[1]:-}"
if [[ "$PARENT_SCRIPT" == startup.sh ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# PROJECT_ROOT is the project root
# Directory structure: project_root/provisioning/dev/scripts/{misc,steps/step-XX/}
# From misc: misc -> scripts -> dev -> provisioning -> project_root (4 levels up)
# From steps: steps/step-XX -> steps -> scripts -> dev -> provisioning -> project_root (5 levels up)
if [[ "${SCRIPT_DIR}" == */steps/* ]]; then
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
else
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
fi

KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/../opentofu/kubeconfig}"
START_TIME=$(date +%s)

# ---- Log helpers: go through tee to startup.log only (fd 1/2 tee) -------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_step() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${PROJECT_ROOT}/startup.log" 2>/dev/null || true; }
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
  if [ "${status}" = "DONE" ]; then
    log "✓ Step ${_STEP_COUNTER} completed in ${mins}m ${secs}s"
  else
    log "✗ Step ${_STEP_COUNTER} FAILED: ${detail:-unknown error}"
  fi
  log ""
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

export KUBECONFIG PROJECT_ROOT CIDR_BASE CIDR_BLOCK GATEWAY_IP CONTROL_PLANE_IP
# preamble.sh — shared bootstrapping for all provisioning scripts
# Source at the top of every script (after the header comment block):
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"
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
#   table_register()   — register a pipeline step for the live progress table
#   table_slot_status()— update a step status, redraws table on fd 3
#   table_redraw()     — redraw the whole table in-place (cursor-up + redraw)
#   START_TIME         — epoch seconds for duration computation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/../opentofu/kubeconfig}"
START_TIME=$(date +%s)

# ---- Log helpers: go through tee to startup.log only (fd 1/2) -------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err()  { log "ERROR: $*"; }
die()  {
  local msg="$*"
  err "$msg"
  printf "\n\e[1;31m✖ FATAL: %s\e[0m\n" "$msg" >&3 2>/dev/null || true
  exit 1
}

# ---- Pipeline table — live-updating progress table on fd 3 -----------------
# Table writes to fd 3 (raw terminal), bypassing the tee log pipeline.
# The bootstrap monitor writes its status to a shared file; table_redraw
# reads it and includes it as a detail line below the table footer.
_TABLE_STEPS=()
_TABLE_LABELS=()
_TABLE_STATUS=()
_TABLE_DETAIL=()
_TABLE_SEEN=0
_TABLE_POLLER_PID=""

MONITOR_STATUS_FILE="${PROJECT_ROOT}/.gsd/bootstrap-monitor-status"

# Register a step in the pipeline table.
# Usage: table_register "0" "Provision Talos VMs (OpenTofu)"
table_register() {
  local step="$1"
  local label="$2"
  _TABLE_STEPS+=("$step")
  _TABLE_LABELS+=("$label")
  _TABLE_STATUS+=("⏳")
  _TABLE_DETAIL+=("waiting")
  _TABLE_TOP=$(( ${#_TABLE_STEPS[@]} + 5 ))
}

# Update the status of a pipeline step and redraw the table.
# Usage: table_slot_status "0" "✅" ""
table_slot_status() {
  local step="$1"
  local status="$2"
  local detail="${3:-}"

  for i in "${!_TABLE_STEPS[@]}"; do
    if [ "${_TABLE_STEPS[$i]}" = "$step" ]; then
      _TABLE_STATUS[$i]="$status"
      _TABLE_DETAIL[$i]="$detail"
      log "TABLE: step ${step} ${status}"
      table_redraw
      return
    fi
  done
}

# Internal: redraw the entire table on fd 3.
# Reads MONITOR_STATUS_FILE for a live detail line below the footer.
table_redraw() {
  local h="${_TABLE_TOP}"

  if [ "$_TABLE_SEEN" -ne 0 ]; then
    printf "\e[%dA\e[J" "$h" >&3 2>/dev/null || true
  fi
  _TABLE_SEEN=1

  local elapsed=$(( $(date +%s) - START_TIME ))
  local e_min=$(( elapsed / 60 ))
  local e_sec=$(( elapsed % 60 ))

  # Read bootstrap monitor status from shared file
  local monitor_line=""
  if [ -f "${MONITOR_STATUS_FILE}" ]; then
    monitor_line="$(head -1 "${MONITOR_STATUS_FILE}" 2>/dev/null || true)"
  fi

  printf "\e[1;37m┌──────┬───────────────────────────────────────────┬────────────────┐\e[0m\n" >&3
  printf "│ \e[1;37m#\e[0m   │ \e[1;37mStep\e[0m                                       │ \e[1;37mStatus\e[0m        │\n" >&3
  printf "├──────┼───────────────────────────────────────────┼────────────────┤\n" >&3

  local i
  for i in "${!_TABLE_STEPS[@]}"; do
    local num="${_TABLE_STEPS[$i]}"
    local label="${_TABLE_LABELS[$i]}"
    local stat="${_TABLE_STATUS[$i]}"
    local det="${_TABLE_DETAIL[$i]}"

    local row_color="37"
    case "$stat" in
      "✅") row_color="32" ;;
      "❌") row_color="31" ;;
      "⏳") row_color="33" ;;
      "⏭") row_color="90" ;;
    esac

    [ "${#label}" -gt 41 ] && label="${label:0:38}..."
    label="$(printf "%-41s" "$label")"

    local stat_cell="${stat}${det:+ ${det}}"
    stat_cell="$(printf "%-14s" "$stat_cell")"
    stat_cell="${stat_cell:0:14}"

    printf "│ \e[%sm%-3s\e[0m│ \e[%sm%s\e[0m │ \e[%sm%s\e[0m│\n" \
      "$row_color" "$num" "$row_color" "$label" "$row_color" "$stat_cell" >&3
  done

  # Footer
  local elapsed_str=""
  if [ "${e_min}" -gt 0 ]; then
    elapsed_str="\e[90m[${e_min}m ${e_sec}s]\e[0m"
  else
    elapsed_str="\e[90m[${e_sec}s]\e[0m"
  fi

  if [ -n "${monitor_line}" ] && [ "${monitor_line}" != "done" ]; then
    printf "└──────┴───────────────────────────────────────────┴────────────────┘  %s  \e[90m%s\e[0m\n" \
      "${elapsed_str}" "${monitor_line}" >&3
  else
    printf "└──────┴───────────────────────────────────────────┴────────────────┘  %s\n" \
      "${elapsed_str}" >&3
  fi
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
    printf "\r  Internet: \e[33mnot reachable\e[0m — waiting... [%ds]  " "$((poll_count * 10))" >&3 2>/dev/null || true
    sleep 10
  done
  printf "\r  Internet: \e[32mconnected\e[0m — continuing.                       \n" >&3 2>/dev/null || true
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
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

command -v kubectl >/dev/null 2>&1 || log "  Warning: kubectl not found in PATH"
command -v helm >/dev/null 2>&1    || log "  Warning: helm not found in PATH"

export KUBECONFIG PROJECT_ROOT

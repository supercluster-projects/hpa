# preamble.sh — shared bootstrapping for all provisioning scripts
# Source at the top of every script (after the header comment block):
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"
#
# Provides:
#   SCRIPT_DIR         — absolute path to provisioning/dev/scripts/
#   PROJECT_ROOT       — absolute path to the worktree/project root
#   KUBECONFIG         — default kubeconfig path (overridable via env or --kubeconfig)
#   log()              — timestamped stderr logging
#   err()              — ERROR-prefixed log
#   die()              — error log + exit 1
#   require_env()      — fail with clear message if env var is not set
#   check_internet()   — check if internet is reachable (DNS + HTTP)
#   wait_for_internet() — poll until internet comes back, 10s interval
#   START_TIME         — epoch seconds for duration computation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/../opentofu/kubeconfig}"
START_TIME=$(date +%s)

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err()  { log "ERROR: $*"; }
die()  { err "$*"; exit 1; }

# ---- Internet connectivity helpers ----------------------------------------
# Checks if internet is reachable by testing DNS resolution and HTTP GET
# to a reliable public endpoint. Uses short timeouts to avoid hanging.
INTERNET_CHECK_HOSTS="google.com 1.1.1.1 8.8.8.8"
INTERNET_CHECK_URL="https://google.com/generate_204"

check_internet() {
  local host=""
  # Try DNS resolution against each known host
  for host in ${INTERNET_CHECK_HOSTS}; do
    if timeout 3 nslookup "${host}" 2>/dev/null | grep -q "Address"; then
      # DNS works — now verify HTTP GET (200 or 204 response)
      if timeout 5 curl -sI "${INTERNET_CHECK_URL}" 2>/dev/null | grep -qE "HTTP/[0-9.]+ 20[0-9]"; then
        return 0
      fi
    fi
  done
  # One more attempt: bare TCP connect to port 443 on a known host
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
  while ! check_internet; do
    poll_count=$((poll_count + 1))
    if [ "${poll_count}" -eq 1 ]; then
      log "Waiting for internet connection (required for: ${label})..."
      log "  Checking every 10 seconds — connect and the process resumes automatically."
    fi
    printf "\r  [%ds] Internet: not reachable — waiting..." "$((poll_count * 10))" >&2
    sleep 10
  done
  printf "\r  [%ds] Internet: connected — continuing.                     \n" "$((poll_count * 10))" >&2
  log "Internet connectivity restored."
}

# ---- Environment helpers ---------------------------------------------------
# Require an environment variable; fail with a clear message if unset or empty.
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

# Source .env from project root, if present.
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

command -v kubectl >/dev/null 2>&1 || log "  Warning: kubectl not found in PATH"
command -v helm >/dev/null 2>&1    || log "  Warning: helm not found in PATH"

export KUBECONFIG PROJECT_ROOT

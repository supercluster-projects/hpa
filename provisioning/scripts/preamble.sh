# preamble.sh — shared bootstrapping for all provisioning scripts
# Source at the top of every script (after the header comment block):
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"
#
# Provides:
#   SCRIPT_DIR         — absolute path to provisioning/scripts/
#   PROJECT_ROOT       — absolute path to the worktree/project root
#   KUBECONFIG         — default kubeconfig path (overridable via env or --kubeconfig)
#   log()              — timestamped stderr logging
#   err()              — ERROR-prefixed log
#   die()              — error log + exit 1
#   require_env()      — fail with clear message if env var is not set
#   START_TIME         — epoch seconds for duration computation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/../dev/kubeconfig}"
START_TIME=$(date +%s)

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err()  { log "ERROR: $*"; }
die()  { err "$*"; exit 1; }

# Require an environment variable; fail with a clear message if unset or empty.
# Skips variables starting with TF_VAR_ (OpenTofu handles those).
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

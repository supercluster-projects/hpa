# preamble.sh — shared bootstrapping for all provisioning scripts
# Source at the top of every script (after the header comment block):
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"
#
# Provides:
#   SCRIPT_DIR         — absolute path to provisioning/scripts/
#   KUBECONFIG         — default kubeconfig path (overridable via env or --kubeconfig)
#   log()              — timestamped stderr logging
#   err()              — ERROR-prefixed log
#   die()              — error log + exit 1
#   kubectl/helm       — preflight check (warning only, not fatal)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/../tofu-libvirt-dev/kubeconfig}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err()  { log "ERROR: $*"; }
die()  { err "$*"; exit 1; }

command -v kubectl >/dev/null 2>&1 || log "  Warning: kubectl not found in PATH"
command -v helm >/dev/null 2>&1    || log "  Warning: helm not found in PATH"

export KUBECONFIG

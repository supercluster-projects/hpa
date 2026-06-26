#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cluster-destroy.sh — Destroy a throwaway Talos K8s dev cluster (QEMU)
#
# Wraps talosctl cluster destroy with sensible defaults from .env and CLI
# overrides. Idempotent — safe to run on an already-destroyed cluster.
# Cleans up state directory files (kubeconfig, talosconfig) after success.
#
# Usage: ./cluster-destroy.sh [options]
#
# Options:
#   --name NAME              Cluster name (default: $DEV_CLUSTER_NAME)
#   --state DIR              Talos state directory (default: ~/.talos/clusters/<name>)
#   --force, -f              Force deletion even if errors occurred
#   --save-logs FILE         Save cluster logs archive to path before destroy
#   --save-support FILE      Save support archive to path before destroy
#   --help, -h               Show this help message
#
# Environment:
#   .env file at project root sourced automatically if present
#   CLI flags override env vars which override script defaults
#
# Requires: talosctl
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults (from .env or built-in) ------------------------------------
CLUSTER_NAME="${DEV_CLUSTER_NAME:-hpa-dev}"
STATE_DIR=""
FORCE=false
SAVE_LOGS_PATH=""
SAVE_SUPPORT_PATH=""

# ---- CLI flag parsing ----------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)            CLUSTER_NAME="$2";         shift 2 ;;
    --state)           STATE_DIR="$2";            shift 2 ;;
    --force|-f)        FORCE=true;                 shift ;;
    --save-logs)       SAVE_LOGS_PATH="$2";       shift 2 ;;
    --save-support)    SAVE_SUPPORT_PATH="$2";     shift 2 ;;
    --help|-h)
      cat <<HELP
Usage: $(basename "$0") [options]

Destroy a Talos QEMU dev cluster created by cluster-create.sh.
Idempotent — safe to run if the cluster is already gone.

Options:
  --name NAME              Cluster name (default: ${DEV_CLUSTER_NAME:-hpa-dev})
  --state DIR              Talos state dir (default: ~/.talos/clusters/<name>)
  --force, -f              Force deletion even if there were errors
  --save-logs FILE         Save cluster logs archive to path
  --save-support FILE      Save support archive to path
  --help, -h               Show this help

Environment:
  .env file at project root sourced automatically if present.
  CLI flags override env vars which override script defaults.

Examples:
  ./cluster-destroy.sh                              # destroy default cluster
  ./cluster-destroy.sh --force                      # force destroy
  ./cluster-destroy.sh --name my-test               # destroy named cluster
  ./cluster-destroy.sh --save-logs /tmp/logs.tar.gz # save logs before clean

Requires: talosctl
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Pre-flight checks ---------------------------------------------------
command -v talosctl >/dev/null 2>&1 || die "talosctl not found in PATH"

# Resolve state directory path
STATE_DIR_FINAL="${STATE_DIR:-${HOME}/.talos/clusters/${CLUSTER_NAME}}"

log "=========================================================="
log "Destroying Talos QEMU cluster: ${CLUSTER_NAME}"
log "=========================================================="
log "  state:  ${STATE_DIR_FINAL}"
[ "${FORCE}" = true ] && log "  force:  true"
[ -n "${SAVE_LOGS_PATH}" ]   && log "  logs:   ${SAVE_LOGS_PATH}"
[ -n "${SAVE_SUPPORT_PATH}" ] && log "  support: ${SAVE_SUPPORT_PATH}"
log ""

# ---- Count existing VMs (before destroy) ---------------------------------
DESTROYED_VMS=0
FAILURES=0

# Count nodes from state dir — talosctl stores per-node data there
if [ -d "${STATE_DIR_FINAL}" ]; then
  # Count VM PID files as a proxy for running nodes
  VM_COUNT=$(find "${STATE_DIR_FINAL}" -maxdepth 2 -name '*.pid' 2>/dev/null | wc -l)
  if [ "${VM_COUNT}" -eq 0 ]; then
    log "  No running VMs detected in state directory."
    log "  The cluster may already be destroyed."
  else
    log "  Detected ${VM_COUNT} VM(s) in state directory."
  fi
else
  log "  Cluster state directory not found at ${STATE_DIR_FINAL}."
  log "  Nothing to destroy — idempotent exit."
  DURATION=$(( $(date +%s) - START_TIME ))
  MINUTES=$(( DURATION / 60 ))
  SECONDS=$(( DURATION % 60 ))
  log ""
  log "=========================================================="
  log "Cluster Destroy Summary"
  log "=========================================================="
  log "  Cluster:  ${CLUSTER_NAME}"
  log "  Destroyed: 0 (cluster did not exist)"
  log "  Failures:  0"
  log "  Duration:  ${MINUTES}m ${SECONDS}s"
  log "=========================================================="
  exit 0
fi

# ---- Build talosctl command -----------------------------------------------
TALOSCTL_CMD=(talosctl cluster destroy
  --name "${CLUSTER_NAME}"
  --state "${STATE_DIR_FINAL}"
)

if [ "${FORCE}" = true ]; then
  TALOSCTL_CMD+=(--force)
fi

if [ -n "${SAVE_LOGS_PATH}" ]; then
  TALOSCTL_CMD+=(--save-cluster-logs-archive-path "${SAVE_LOGS_PATH}")
fi

if [ -n "${SAVE_SUPPORT_PATH}" ]; then
  TALOSCTL_CMD+=(--save-support-archive-path "${SAVE_SUPPORT_PATH}")
fi

# ---- Run talosctl ----------------------------------------------------------
log "Running talosctl cluster destroy..."
log "  Command: ${TALOSCTL_CMD[*]}"
log ""

# Trap on interrupt for user feedback
interrupted() {
  log ""
  log "Interrupt received. The state directory may be inconsistent."
  log "  Retry with: cluster-destroy.sh --force"
  exit 1
}
trap interrupted SIGINT SIGTERM

if "${TALOSCTL_CMD[@]}"; then
  log "talosctl cluster destroy completed successfully."
  DESTROYED_VMS="${VM_COUNT}"
else
  DESTROYED_VMS="${VM_COUNT}"
  FAILURES=$(( FAILURES + 1 ))
  log "  Warning: talosctl cluster destroy reported an error."
  if [ "${FORCE}" = false ]; then
    log "  Retry with --force to force-clean the state directory."
  fi
fi

# ---- Clean up left-over state files ---------------------------------------
log ""
log "Cleaning up state directory files..."

CLEANUP_FAILURES=0
if [ -f "${STATE_DIR_FINAL}/kubeconfig" ]; then
  rm -f "${STATE_DIR_FINAL}/kubeconfig" \
    && log "  Removed kubeconfig" \
    || { log "  Failed to remove kubeconfig"; CLEANUP_FAILURES=$(( CLEANUP_FAILURES + 1 )); }
fi

if [ -f "${STATE_DIR_FINAL}/talosconfig" ]; then
  rm -f "${STATE_DIR_FINAL}/talosconfig" \
    && log "  Removed talosconfig" \
    || { log "  Failed to remove talosconfig"; CLEANUP_FAILURES=$(( CLEANUP_FAILURES + 1 )); }
fi

if [ "${CLEANUP_FAILURES}" -gt 0 ]; then
  log "  ${CLEANUP_FAILURES} cleanup item(s) failed."
  FAILURES=$(( FAILURES + CLEANUP_FAILURES ))
fi

# ---- Summary ---------------------------------------------------------------
DURATION=$(( $(date +%s) - START_TIME ))
MINUTES=$(( DURATION / 60 ))
SECONDS=$(( DURATION % 60 ))

log ""
log "=========================================================="
log "Cluster Destroy Summary"
log "=========================================================="
log "  Cluster:  ${CLUSTER_NAME}"
if [ "${DESTROYED_VMS}" -gt 0 ] && [ "${FAILURES}" -eq 0 ]; then
  log "  Result:   Cluster destroyed successfully"
elif [ "${DESTROYED_VMS}" -eq 0 ]; then
  log "  Result:   Cluster was already gone"
else
  log "  Result:   Destroy completed with ${FAILURES} failure(s)"
fi
log "  Destroyed: ${DESTROYED_VMS} VM(s)"
log "  Failures:  ${FAILURES}"
log "  Duration:  ${MINUTES}m ${SECONDS}s"
log ""
log "  The cluster ${CLUSTER_NAME} has been destroyed."
log "=========================================================="

if [ "${FAILURES}" -gt 0 ]; then
  exit 1
fi
exit 0

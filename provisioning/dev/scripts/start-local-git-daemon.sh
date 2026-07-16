#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# start-local-git-daemon.sh — Launch Host-Side Git Daemon for Local Sync (Option 1)
#
# Starts a lightweight local Git daemon on your workstation host. 
# This allows the virtualized Argo CD / Kargo agents running inside the LibVirt
# VMs to pull manifests directly from your local filesystem via the bridge
# gateway IP (192.168.122.1) without relying on the internet.
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { log "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ---- Configuration --------------------------------------------------------
PORT=9418
BRIDGE_IP="192.168.122.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# ---- Check dependencies ---------------------------------------------------
command -v git >/dev/null 2>&1 || die "git CLI is required but not found."

log "=== Starting Local Host Git Daemon ==="
log "  Project Root: ${PROJECT_ROOT}"
log "  Host Bridge Gateway IP: ${BRIDGE_IP}"
log "  Daemon Port:  ${PORT}"
log "  ArgoCD Target URL: git://${BRIDGE_IP}/with-gsd"
log "======================================="

# Verify if git daemon port is already bound
if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
  err "Port ${PORT} is already in use. Git daemon may already be running."
  log "Check active processes: ps aux | grep 'git daemon'"
  exit 1
fi

log "Starting git daemon on ${BRIDGE_IP}:${PORT}..."
# Start git daemon bound to the bridge interface IP
# We specify the base-path as the parent directory so we can pull the project directory (with-gsd)
git daemon \
  --base-path="${PROJECT_ROOT}/.." \
  --listen="${BRIDGE_IP}" \
  --port="${PORT}" \
  --export-all \
  --reuseaddr \
  --informative-errors

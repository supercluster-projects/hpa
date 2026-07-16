#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# register-spoke-cluster.sh — Automate Spoke Cluster Onboarding & Bootstrap (M5 Task M5.1.2)
#
# Registers a new Spoke cluster with the central Management Hub and generates
# the JSON descriptor to trigger immediate dynamic Argo CD bootstrapping.
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { log "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ---- Preflight ------------------------------------------------------------
[ $# -lt 3 ] && die "Usage: $0 <spoke-name> <spoke-api-ip> <bearer-token>"

SPOKE_NAME="$1"
SPOKE_IP="$2"
BEARER_TOKEN="$3"

log "=== Initializing Onboarding for Spoke Cluster '${SPOKE_NAME}' ==="

# Define directories
ONBOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_ROOT="$(cd "${ONBOARD_DIR}/.." && pwd)"
CLUSTERS_DIR="${FLEET_ROOT}/clusters"

mkdir -p "${CLUSTERS_DIR}"

# ---- Step 1: Generate Argo CD registration Secret (Task M5.1.2) -----------
log "Step 1: Creating cluster registration secret manifest..."
cat > "${ONBOARD_DIR}/${SPOKE_NAME}-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SPOKE_NAME}-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${SPOKE_NAME}
  server: "https://${SPOKE_IP}:6443"
  config: |
    {
      "bearerToken": "${BEARER_TOKEN}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF
log "  Secret manifest generated: ${SPOKE_NAME}-secret.yaml"

# ---- Step 2: Generate Git File Generator JSON (Task M5.1.1 & M5.1.2) ------
log "Step 2: Generating Git File Generator JSON descriptor..."
cat > "${CLUSTERS_DIR}/${SPOKE_NAME}.json" <<EOF
{
  "cluster": {
    "name": "${SPOKE_NAME}",
    "server": "https://${SPOKE_IP}:6443"
  }
}
EOF
log "  JSON descriptor generated: clusters/${SPOKE_NAME}.json"

log "=== Onboarding Manifests Created successfully! ==="
log "  Apply secret to Hub:  kubectl apply -f onboarding/${SPOKE_NAME}-secret.yaml"
log "  Commit and Push JSON: Git commit clusters/${SPOKE_NAME}.json to trigger bootstrap."
exit 0

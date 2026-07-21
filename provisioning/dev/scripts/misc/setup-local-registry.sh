#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-local-registry.sh — Set up local OCI registry for offline bootstrap
#
# Creates a local Docker registry on the host to serve images to the
# Talos VMs during offline bootstrap. This is required for air-gapped
# deployments where the cluster cannot pull images from the internet.
#
# The script:
# 1. Starts a local registry container (if not already running)
# 2. Downloads bootstrap images (etcd, kube-apiserver, kubelet, etc.)
# 3. Loads them into the local registry
#
# Usage: ./setup-local-registry.sh [--seed-dir <path>]
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../.env"
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

# ---- Configuration -----------------------------------------------------------
REGISTRY_HOST="${DEV_BRIDGE_GATEWAY:-192.168.122.1}"
REGISTRY_PORT=5000
SEED_DIR="${SEED_DIR:-/media/seed-appliance}"
REGISTRY_NAME="hpa-local-registry"

# ---- Bootstrap images required for Talos v1.13 + Kubernetes v1.36 -----------
BOOTSTRAP_IMAGES=(
  "registry.k8s.io/etcd:v3.6.12"
  "registry.k8s.io/kube-apiserver:v1.36.0"
  "registry.k8s.io/kube-controller-manager:v1.36.0"
  "registry.k8s.io/kube-scheduler:v1.36.0"
  "ghcr.io/siderolabs/kubelet:v1.36.0"
  "ghcr.io/siderolabs/installer:v1.13.5"
  "ghcr.io/siderolabs/installer:v1.13.0"
  "registry.k8s.io/pause:3.10"
  "registry.k8s.io/pause:3.10.1"
  "registry.k8s.io/pause:3.9"
)

# ---- Function to check if registry is running -------------------------------
check_registry() {
  if docker exec "${REGISTRY_NAME}" 2>/dev/null; then
    if curl -s "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" | grep -q "{}"; then
      return 0
    fi
  fi
  return 1
}

# ---- Function to start registry --------------------------------------------
start_registry() {
  log "Starting local registry at ${REGISTRY_HOST}:${REGISTRY_PORT}..."

  # Remove existing registry if present
  docker rm -f "${REGISTRY_NAME}" 2>/dev/null || true

  # Start registry (:z suffix for SELinux relabeling)
  docker run -d \
    --name "${REGISTRY_NAME}" \
    --restart unless-stopped \
    -p "${REGISTRY_PORT}:5000" \
    -v "${SCRIPT_DIR}/registry-data:/var/lib/registry:z" \
    registry:2

  # Wait for registry to be ready
  for i in {1..30}; do
    if curl -s "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" | grep -q "{}"; then
      log "Registry is ready!"
      return 0
    fi
    sleep 1
  done

  log "ERROR: Registry failed to start"
  return 1
}

# ---- Function to pull and push images --------------------------------------
sync_image() {
  local image="$1"
  local img_name="${image#*/}"
  local img_name="${img_name//\//-}"

  log "Syncing ${image}..."

  # Use skopeo for multi-arch image support (docker push fails on multi-arch)
  if command -v skopeo >/dev/null 2>&1; then
    log "  Using skopeo (multi-arch safe)..."
    skopeo copy --dest-tls-verify=false "docker://${image}" "docker://${REGISTRY_HOST}:${REGISTRY_PORT}/${image#*/}" 2>&1 && {
      log "  ✓ ${image} seeded via skopeo"
      return 0
    }
    log "  Warning: skopeo failed, trying docker pull/tag/push..."
  fi

  # Fallback: Pull from upstream, tag, push via docker
  if docker pull "${image}" 2>/dev/null; then
    local local_tag="${image/registry.k8s.io/${REGISTRY_HOST}:${REGISTRY_PORT}}"
    local_tag="${local_tag/ghcr.io/${REGISTRY_HOST}:${REGISTRY_PORT}}"
    docker tag "${image}" "${local_tag}"
    docker push "${local_tag}" 2>/dev/null || log "Warning: Could not push ${local_tag}"
  else
    log "Warning: Could not pull ${image} - may already be in seed or offline"
  fi
}

# ---- Main -------------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "setup-local-registry: starting"
log "  Registry: ${REGISTRY_HOST}:${REGISTRY_PORT}"
log "  Seed dir: ${SEED_DIR}"

# Create registry data directory
mkdir -p "${SCRIPT_DIR}/registry-data"

# Start registry if not running
if ! check_registry; then
  start_registry || log "Warning: Could not start registry"
else
  log "Registry already running"
fi

# Sync bootstrap images
for image in "${BOOTSTRAP_IMAGES[@]}"; do
  sync_image "${image}"
done

log "Local registry should now have ${#BOOTSTRAP_IMAGES[@]} bootstrap images"
log "setup-local-registry: completed"
exit 0
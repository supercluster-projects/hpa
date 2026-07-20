#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# seed-bootstrap-images.sh — Seed Kubernetes bootstrap images to local registry
#
# This script pulls Kubernetes control plane images and pushes them to a local
# registry (or Harbor) for offline/bootstrap scenarios.
#
# Usage: ./seed-bootstrap-images.sh [REGISTRY_URL] [HARBOR_USER] [HARBOR_PASS]
#
# Environment:
#   KUBERNETES_VERSION - Override k8s version (default: auto-detect from Talos)
#   HARBOR_ADMIN_USER  - Admin username for Harbor (default: admin)
#   HARBOR_ADMIN_PASS  - Admin password for Harbor (default: Harbor12345!)
#
# Exit: 0 on success, non-zero on failure
# ---------------------------------------------------------------------------
set -euo pipefail

REGISTRY_URL="${1:-192.168.122.1:5000}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-Harbor12345!}"

# Determine Kubernetes version from container images
# Talos 1.13.x uses Kubernetes 1.36.x
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.36.0}"
TALOS_VERSION="${TALOS_VERSION:-1.13.5}"

# Bootstrap images needed for control plane
BOOTSTRAP_IMAGES=(
  "registry.k8s.io/etcd:v3.6.12"
  "registry.k8s.io/kube-apiserver:v1.36.0"
  "registry.k8s.io/kube-controller-manager:v1.36.0"
  "registry.k8s.io/kube-scheduler:v1.36.0"
  "ghcr.io/siderolabs/kubelet:v1.36.0"
)

# Additional Talos system images
TALOS_IMAGES=(
  "ghcr.io/siderolabs/talos:v1.13.5"
  "ghcr.io/siderolabs/talos-amd64:v1.13.5"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
die() { log "ERROR: $1"; exit 1; }

# Check for Docker
command -v docker >/dev/null 2>&1 || {
  log "WARNING: Docker not found, using buildah..."
  command -v buildah >/dev/null 2>&1 || die "Neither docker nor buildah found"
  USE_DOCKER=false
}

log "Seeding bootstrap images to ${REGISTRY_URL}..."
log "Kubernetes version: ${KUBERNETES_VERSION}"
log ""

# Login to registry
log "Logging in to registry ${REGISTRY_URL}..."
if [ -n "${HARBOR_PASS}" ]; then
  echo "${HARBOR_PASS}" | docker login "${REGISTRY_URL}" -u "${HARBOR_USER}" --password-stdin 2>/dev/null || \
  echo "${HARBOR_PASS}" | buildah login "${REGISTRY_URL}" -u "${HARBOR_USER}" --password-stdin 2>/dev/null || \
    log "Warning: Could not authenticate to registry, proceeding anyway..."
fi

# Process each bootstrap image
for img in "${BOOTSTRAP_IMAGES[@]}"; do
  log "Processing ${img}..."
  
  # Extract image name and tag
  IMG_NAME=$(echo "$img" | cut -d: -f1)
  IMG_TAG=$(echo "$img" | cut -d: -f2)
  IMG_SHORT_NAME=$(echo "$IMG_NAME" | sed 's|registry.k8s.io/|k8s.gcr.io/|; s|ghcr.io/siderolabs/|siderolabs/|')
  
  # Pull from upstream
  log "  Pulling ${img}..."
  docker pull "${img}" 2>/dev/null || buildah pull "docker-daemon://${img}" 2>/dev/null || {
    log "  Warning: Could not pull ${img}, checking if already in local cache..."
  }
  
  # Create Harbor-compatible tag (replace / with _)
  REGISTRY_TAG="${REGISTRY_URL}/library/${IMG_SHORT_NAME}:${IMG_TAG}"
  
  # Tag for registry
  log "  Tagging as ${REGISTRY_TAG}..."
  docker tag "${img}" "${REGISTRY_TAG}" 2>/dev/null || \
    buildah tag "docker-daemon://${img}" "docker-daemon://${REGISTRY_TAG}" 2>/dev/null || \
    log "  Warning: Could not tag image"
  
  # Push to registry
  log "  Pushing to ${REGISTRY_URL}..."
  docker push "${REGISTRY_TAG}" 2>/dev/null || \
    buildah push "docker-daemon://${REGISTRY_TAG}" 2>/dev/null || \
    log "  Warning: Could not push ${img}"
  
  log "  ✓ ${img} seeded"
done

# Process Talos images
for img in "${TALOS_IMAGES[@]}"; do
  log "Processing Talos image ${img}..."
  
  docker pull "${img}" 2>/dev/null || buildah pull "docker-daemon://${img}" 2>/dev/null || {
    log "  Warning: Could not pull ${img}, checking if already in local cache..."
  }
  
  REGISTRY_TAG="${REGISTRY_URL}/library/talos:${IMG_TAG}"
  
  docker tag "${img}" "${REGISTRY_TAG}" 2>/dev/null || \
    buildah tag "docker-daemon://${img}" "docker-daemon://${REGISTRY_TAG}" 2>/dev/null || \
    log "  Warning: Could not tag image"
  
  docker push "${REGISTRY_TAG}" 2>/dev/null || \
    buildah push "docker-daemon://${REGISTRY_TAG}" 2>/dev/null || \
    log "  Warning: Could not push ${img}"
  
  log "  ✓ ${img} seeded"
done

log ""
log "Bootstrap images seeded successfully!"
log "Registry: ${REGISTRY_URL}"

# Print registry mirror config snippet for Talos config
echo ""
echo "# Add to containerd configuration in cluster-config.yaml.tftpl:"
echo "[plugins.\"io.containerd.cri.v1.images\".registry]"
echo "  [plugins.\"io.containerd.cri.v1.images\".registry.mirrors]"
echo "    [plugins.\"io.containerd.cri.v1.images\".registry.mirrors.\"registry.k8s.io\"]"
echo "      endpoint = [\"http://${REGISTRY_URL}\"]"
echo "    [plugins.\"io.containerd.cri.v1.images\".registry.mirrors.\"ghcr.io\"]"
echo "      endpoint = [\"http://${REGISTRY_URL}\"]"
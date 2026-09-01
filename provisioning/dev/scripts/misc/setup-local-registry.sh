#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-local-registry.sh — Set up local OCI registry for offline bootstrap
#
# Starts a host-local registry at ${REGISTRY_HOST}:${REGISTRY_PORT} and seeds
# the Talos/Kubernetes bootstrap images that Talos needs before Cilium is
# installed. Talos machine config mirrors registry.k8s.io/ghcr.io/quay.io to
# this host endpoint when OFFLINE_MODE=true.
#
# Usage: ./setup-local-registry.sh [--host <REGISTRY_HOST>]
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../.env"
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

# ---- Configuration -----------------------------------------------------------
REGISTRY_HOST="${REGISTRY_HOST:-${DEV_BRIDGE_GATEWAY:-192.168.122.1}}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
SEED_DIR="${SEED_DIR:-/media/seed-appliance}"
REGISTRY_NAME="${REGISTRY_NAME:-hpa-local-registry}"
REGISTRY_DATA_DIR="${REGISTRY_DATA_DIR:-${SCRIPT_DIR}/registry-data}"

# ---- Helpers -----------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

die() {
  log "ERROR: $1"
  exit 1
}

sudo_password() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    return 0
  fi
  if [ "${SUDO_PASSWORD_PROMPTED:-0}" = "1" ]; then
    die "SUDO_PASSWORD is not set and sudo password prompt was already shown"
  fi
  printf '\n' >&3 2>/dev/null || true
  read -r -s -p "Enter sudo password: " SUDO_PASSWORD
  printf '\n' >&3 2>/dev/null || true
  SUDO_PASSWORD_PROMPTED=1
  [ -n "${SUDO_PASSWORD:-}" ] || die "SUDO_PASSWORD is required for sudo operations"
}

run_as_root() {
  command -v sudo >/dev/null 2>&1 || die "sudo command not found"
  if sudo -n true &>/dev/null; then
    sudo "$@"
    return $?
  fi
  sudo_password
  printf '%s\n' "${SUDO_PASSWORD}" | sudo -S "$@"
}

# ---- Function to check if registry is running -------------------------------
check_registry() {
  if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != "true" ]; then
    return 1
  fi
  curl -fsS "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" 2>/dev/null | grep -q "{}"
}

# ---- Function to start registry --------------------------------------------
start_registry() {
  log "Starting local registry container '${REGISTRY_NAME}' at ${REGISTRY_HOST}:${REGISTRY_PORT}..."

  docker rm -f "${REGISTRY_NAME}" 2>/dev/null || true
  docker volume create "${REGISTRY_NAME}-data" >/dev/null 2>&1 || true
  docker run -d \
    --name "${REGISTRY_NAME}" \
    --restart unless-stopped \
    -p "${REGISTRY_PORT}:5000" \
    -v "${REGISTRY_DATA_DIR}:/var/lib/registry:z" \
    registry:2 >/dev/null

  for _ in $(seq 1 60); do
    if curl -fsS "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" 2>/dev/null | grep -q "{}"; then
      log "Registry is ready"
      break
    fi
    sleep 1
  done

  if ! curl -fsS "http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" 2>/dev/null | grep -q "{}"; then
    docker logs "${REGISTRY_NAME}" 2>/dev/null | tail -40 || true
    die "Registry failed to become ready"
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    run_as_root firewall-cmd --zone=libvirt --add-port=5000/tcp --permanent >/dev/null 2>&1 || true
    run_as_root firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

# ---- Function to pull and push images --------------------------------------
seed_image() {
  local image="$1"
  local img_name="${image#*/}"
  local dest="docker://${REGISTRY_HOST}:${REGISTRY_PORT}/${img_name}"

  log "Seeding ${image} into ${dest}..."

  if command -v skopeo >/dev/null 2>&1; then
    if skopeo copy \
      --src-tls-verify=false \
      --dest-tls-verify=false \
      "docker://${image}" "${dest}" 2>&1 | tee /tmp/setup-local-registry-skopeo.log; then
      log "  ✓ ${image} seeded via skopeo"
      return 0
    fi
    log "  skopeo copy failed; trying docker pull/tag/push fallback"
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker pull --platform linux/amd64 "${image}" 2>&1 | tee /tmp/setup-local-registry-docker-pull.log; then
      local local_tag="${image/registry.k8s.io/${REGISTRY_HOST}:${REGISTRY_PORT}}"
      local_tag="${local_tag/ghcr.io/${REGISTRY_HOST}:${REGISTRY_PORT}}"
      local_tag="${local_tag/quay.io/${REGISTRY_HOST}:${REGISTRY_PORT}}"
      local_tag="${local_tag/docker.io/${REGISTRY_HOST}:${REGISTRY_PORT}}"
      docker tag "${image}" "${local_tag}" 2>&1 | tee /tmp/setup-local-registry-docker-tag.log
      docker push "${local_tag}" 2>&1 | tee /tmp/setup-local-registry-docker-push.log
      log "  ✓ ${image} seeded via docker fallback"
      return 0
    fi
  fi

  log "  WARNING: Could not seed ${image}; Talos bootstrap may fail if it is not already present on the node"
  return 0
}

# ---- Main --------------------------------------------------------------------
log "setup-local-registry: starting"
log "  Registry host: ${REGISTRY_HOST}"
log "  Registry port: ${REGISTRY_PORT}"
log "  Seed dir: ${SEED_DIR}"

command -v docker >/dev/null 2>&1 || die "docker command not found"
command -v curl >/dev/null 2>&1 || die "curl command not found"

mkdir -p "${REGISTRY_DATA_DIR}"

if ! check_registry; then
  start_registry
else
  log "Registry already running"
fi

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

for image in "${BOOTSTRAP_IMAGES[@]}"; do
  seed_image "${image}"
done

log "Local registry should now have ${#BOOTSTRAP_IMAGES[@]} bootstrap images"
log "setup-local-registry: completed"
exit 0

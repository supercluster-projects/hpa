#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# offline-bootstrap.sh — Fully offline bootstrap for dev HPA cluster
#
# This script implements the complete OFFLINE bootstrap workflow:
#   1) PREPARE stage – ensure all VM images are present and valid
#   2) STARTUP  – always run startup.sh (which will skip Terraform if cluster
#                 is already healthy)
#   3) BOOTSTRAP– run Talos bootstrap ONLY if images were prepared or updated
#
# The bootstrap process must be OFFLINE completely if any image is missing
# (or version updated) – in that case the prepare stage must be re-run
# first to pull/build the required images.
# ---------------------------------------------------------------------------
set -euo pipefail

# Source common environment and helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
: "${LOCAL_IMAGE_PATH:=}"
: "${TALOS_VERSION:=v1.13.5}"
: "${DEV_CLUSTER_NAME:=hpa-dev}"
: "${DEV_CP_COUNT:=1}"
: "${DEV_WORKER_COUNT:=3}"
: "${DEV_VM_CPU:=4}"
: "${DEV_CP_RAM_MB:=4096}"
: "${DEV_WORKER_RAM_MB:=4096}"
: "${DEV_OS_DISK_SIZE_GB:=40}"
: "${DEV_CEPH_DISK_SIZE_GB:=100}"
: "${DEV_BRIDGE_NAME:=hpa-bridge}"
: "${DEV_NODE_PREFIX:=hpa-node}"
: "${DEV_CIDR_BLOCK:=192.168.122.0/24}"
: "${GATEWAY_IP:=192.168.122.1}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_step() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  log_step "ERROR: $*"
  exit 1
}

# ---------------------------------------------------------------------------
# Stage 0 – Pre-flight checks
# ---------------------------------------------------------------------------
log_step "=== PRE-FLIGHT CHECKS ==="

command -v qemu-img >/dev/null 2>&1 || fail "qemu-img not found in PATH"
command -v virsh  >/dev/null 2>&1 || fail "virsh not found in PATH"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found in PATH"

# Check libvirtd is running
if ! virsh nodeinfo &>/dev/null; then
  log_step "WARNING: libvirtd does not appear responsive – attempting restart"
  systemctl restart libvirtd || fail "Failed to restart libvirtd"
  sleep 3
fi

# ---------------------------------------------------------------------------
# Stage 1 – PREPARE images (OFFLINE)
# ---------------------------------------------------------------------------
log_step "=== PREPARE STAGE (OFFLINE IMAGE BUILD/CHECK) ==="

IMAGES_DIR="${PROJECT_ROOT}/prebuilt-images"
BASE_RAW="${IMAGES_DIR}/talos-base.raw"
BASE_QCOW2="${IMAGES_DIR}/talos-base.qcow2"
WORKER_QCOW2_PATTERN="${IMAGES_DIR}/hpa-node-worker-%d-os.qcow2"

# Determine if we need to prepare images
NEED_PREPARE=false
PREPARE_REASON=""

if [ -n "${LOCAL_IMAGE_PATH:-}" ]; then
  if [ ! -f "${LOCAL_IMAGE_PATH}" ]; then
    fail "Local image path specified but file not found: ${LOCAL_IMAGE_PATH}"
  fi
  log_step "Using provided local image: ${LOCAL_IMAGE_PATH}"
  # If local image differs from what we have cached, we need to re-prepare
  if [ ! -f "${BASE_QCOW2}" ]; then
    NEED_PREPARE=true
    PREPARE_REASON="No cached base QCOW2 found"
  fi
else
  # Try to use the factory URL – check if cached QCOW2 exists and is recent
  if [ ! -f "${BASE_QCOW2}" ]; then
    NEED_PREPARE=true
    PREPARE_REASON="Base QCOW2 not cached"
  else
    log_step "Base QCOW2 cache found: ${BASE_QCOW2}"
  fi

  # Verify each worker image exists
  for i in $(seq 0 $((DEV_WORKER_COUNT - 1))); do
    WORKER_IMG="${IMAGES_DIR}/hpa-node-worker-${i}-os.qcow2"
    if [ ! -f "${WORKER_IMG}" ]; then
      NEED_PREPARE=true
      PREPARE_REASON="Worker image missing: ${WORKER_IMG}"
      break
    fi
  done
fi

if $NEED_PREPARE; then
  log_step "Images need prepare: ${PREPARE_REASON}"
  log_step "Running prebuild-talos-images.sh..."
  bash "${SCRIPT_DIR}/prebuild-talos-images.sh" \
    --overwrite \
    --output-dir "${IMAGES_DIR}" || fail "Image prebuild failed"
  log_step "Image prebuild complete"
else
  log_step "All images present – skipping prepare stage"
fi

# Verify images
log_step "Verifying images..."
qemu-img info "${BASE_QCOW2}" &>/dev/null || fail "Base QCOW2 invalid"
for i in $(seq 0 $((DEV_WORKER_COUNT - 1))); do
  WORKER_IMG="${IMAGES_DIR}/hpa-node-worker-${i}-os.qcow2"
  qemu-img info "${WORKER_IMG}" &>/dev/null || fail "Worker image ${i} invalid"
done
log_step "Image verification passed"

# Copy to libvirt pool if not already there
LIBVIRT_POOL="/var/lib/libvirt/images"
if [ -d "${LIBVIRT_POOL}" ]; then
  log_step "Copying images to libvirt pool ${LIBVIRT_POOL}..."
  cp "${BASE_QCOW2}" "${LIBVIRT_POOL}/talos-base.qcow2"
  for i in $(seq 0 $((DEV_WORKER_COUNT - 1))); do
    WORKER_IMG="${IMAGES_DIR}/hpa-node-worker-${i}-os.qcow2"
    cp "${WORKER_IMG}" "${LIBVIRT_POOL}/hpa-node-worker-${i}-os.qcow2"
  done
  log_step "Images copied to libvirt pool"
fi

# ---------------------------------------------------------------------------
# Stage 2 – STARTUP (always run; will skip TF if cluster already healthy)
# ---------------------------------------------------------------------------
log_step "=== STARTUP STAGE ==="
bash "${SCRIPT_DIR}/startup.sh" \
  --envoy-ip "${GATEWAY_IP}" \
  --tofu-dir "${PROJECT_ROOT}/provisioning/dev/opentofu" \
  --skip-tofu || fail "Startup failed"

log_step "Startup completed – checking cluster health..."

# Wait for nodes to become Ready
log_step "Waiting for nodes to become Ready..."
for _ in $(seq 1 60); do
  READY=$(kubectl get nodes -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status}=="True")].metadata.name' 2>/dev/null | wc -l)
  TOTAL=$((DEV_CP_COUNT + DEV_WORKER_COUNT))
  if [ "${READY}" -ge "${TOTAL}" ]; then
    log_step "All ${TOTAL} nodes Ready"
    break
  fi
  log_step "Ready nodes: ${READY}/${TOTAL} – waiting..."
  sleep 10
done

if [ "${READY}" -lt "${TOTAL}" ]; then
  fail "Timeout waiting for nodes to become Ready (have ${READY}/${TOTAL})"
fi

# ---------------------------------------------------------------------------
# Stage 3 – BOOTSTRAP Talos (only if images were prepared/updated)
# ---------------------------------------------------------------------------
if $NEED_PREPARE; then
  log_step "=== BOOTSTRAP STAGE (Talos from cache) ==="
  log_step "Bootstrapping cluster with Talos config from cache..."

  # Use talosctl with kubeconfig from startup.sh
  KUBECONFIG="${PROJECT_ROOT}/provisioning/dev/opentofu/kubeconfig" \
    talosctl --name "${DEV_CLUSTER_NAME}" \
      --context "${DEV_CLUSTER_NAME}" \
      bootstrap || fail "Talos bootstrap failed"

  log_step "Bootstrap complete – waiting for cluster to stabilize..."
  sleep 30

  # Verify cluster controlplane
  log_step "Verifying cluster health..."
  kubectl --kubeconfig="${KUBECONFIG}" get nodes || fail "kubectl get nodes failed"
  kubectl --kubeconfig="${KUBECONFIG}" get cs || fail "kubectl get cs failed"

  log_step "Cluster bootstrap and verification complete"
else
  log_step "=== BOOTSTRAP SKIPPED ==="
  log_step "Cluster already bootstrapped and healthy (images unchanged)"
fi

log_step "=== OFFLINE BOOTSTRAP WORKFLOW COMPLETE ==="
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup-preflight.sh — Pre-flight cleanup before tofu apply
#
# Destroys all running libvirt VMs matching the node prefix, removes
# OS disk volumes and the Talos ISO, and removes stale entries from
# the local tofu state so they are re-created fresh.
#
# Preserves Ceph storage disks — they are reused across runs.
#
# Called automatically by startup.sh before the tofu apply step.
# Can also be run standalone: ./cleanup-preflight.sh [--prefix hpa-node]
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TOFU_DIR="${TOFU_DIR:-${SCRIPT_DIR}/../opentofu}"

NODE_PREFIX="${NODE_PREFIX:-hpa-node}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) NODE_PREFIX="$2"; shift 2 ;;
    --tofu-dir) TOFU_DIR="$2"; shift 2 ;;
    *) echo "[$(date '+%Y-%m-%d %H:%M:%S')] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err()  { log "ERROR: $*"; }
die()  { err "$*"; exit 1; }

TOFU_ABS_DIR="$(cd "${TOFU_DIR}" 2>/dev/null && pwd)" || die "tofu dir not found"

log "=== Pre-flight cleanup for prefix '${NODE_PREFIX}' ==="

# ---- Step 1: Destroy all VMs matching the node prefix ---------------------
log "Step 1: Destroying VMs matching '${NODE_PREFIX}'..."
VM_NAMES=$(virsh -c qemu:///system list --name --all 2>/dev/null | grep -E "^${NODE_PREFIX}-(cp|worker)-" || true)
if [ -n "${VM_NAMES}" ]; then
  while IFS= read -r vm; do
    [ -z "${vm}" ] && continue
    log "  Destroying VM: ${vm}"
    virsh -c qemu:///system destroy "${vm}" 2>/dev/null || true
    virsh -c qemu:///system undefine --nvram "${vm}" 2>/dev/null || true
  done <<< "${VM_NAMES}"
  log "  All VMs destroyed and undefined."
else
  log "  No VMs found matching prefix '${NODE_PREFIX}'."
fi

# ---- Step 2: Remove OS disk volumes (preserve Ceph disks) -----------------
log "Step 2: Removing OS disk volumes (preserving Ceph disks)..."
VOL_NAMES=$(sudo virsh vol-list default 2>/dev/null | awk -v pre="${NODE_PREFIX}-" '$1 ~ pre && $1 ~ /-os\.qcow2$/ {print $1}' || true)
if [ -n "${VOL_NAMES}" ]; then
  while IFS= read -r vol; do
    [ -z "${vol}" ] && continue
    log "  Deleting OS volume: ${vol}"
    sudo virsh vol-delete --pool default "${vol}" 2>/dev/null || true
  done <<< "${VOL_NAMES}"
  log "  OS volumes removed."
else
  log "  No OS volumes found."
fi

# ---- Step 3: Remove Talos ISO volume --------------------------------------
log "Step 3: Removing Talos ISO volume..."
ISO_VOL=$(sudo virsh vol-list default 2>/dev/null | awk '/talos-v[0-9].*\.iso$/ {print $1}' || true)
if [ -n "${ISO_VOL}" ]; then
  log "  Deleting ISO volume: ${ISO_VOL}"
  sudo virsh vol-delete --pool default "${ISO_VOL}" 2>/dev/null || true
else
  log "  No Talos ISO volume found."
fi

# ---- Step 4: Remove talos-base.qcow2 if it exists -------------------------
log "Step 4: Removing Talos base qcow2 volume..."
BASE_VOL=$(sudo virsh vol-list default 2>/dev/null | awk '/^talos-base\.qcow2$/ {print $1}' || true)
if [ -n "${BASE_VOL}" ]; then
  log "  Deleting base volume: ${BASE_VOL}"
  sudo virsh vol-delete --pool default "${BASE_VOL}" 2>/dev/null || true
else
  log "  No talos-base.qcow2 volume found."
fi

# ---- Step 5: Remove stale libvirt resources from tofu state ---------------
log "Step 5: Removing stale libvirt resources from tofu state..."
cd "${TOFU_ABS_DIR}"

for res_type in "libvirt_domain.node" "libvirt_volume.os_disk" "libvirt_volume.talos_iso" "libvirt_volume.talos_base" "null_resource.download_talos_iso"; do
  for key in $(tofu state list 2>/dev/null | grep "${res_type}" || true); do
    log "  Removing from state: ${key}"
    tofu state rm "${key}" 2>/dev/null || true
  done
done

# Also remove bootstrap/apply resources that depend on fresh VMs
for res_type in talos_machine_configuration_apply talos_machine_bootstrap talos_cluster_kubeconfig; do
  for key in $(tofu state list 2>/dev/null | grep "${res_type}" || true); do
    log "  Removing from state: ${key}"
    tofu state rm "${key}" 2>/dev/null || true
  done
done

# ---- Step 6: Verify Ceph disks are preserved -----------------------------
log "Step 6: Verifying Ceph disks are preserved..."
CEPH_COUNT=$(sudo virsh vol-list default 2>/dev/null | awk -v pre="${NODE_PREFIX}-" '$1 ~ pre && $1 ~ /-ceph\.raw$/ {count++} END {print count+0}' || true)
log "  Ceph disks preserved: ${CEPH_COUNT}"

log "=== Pre-flight cleanup complete. Ready for tofu apply. ==="

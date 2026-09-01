#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup-preflight.sh — Pre-flight cleanup before tofu apply
#
# Destroys all running libvirt VMs matching the node prefix, removes
# OS disk volumes and the Talos base volume, and removes stale entries from
# the local tofu state so they are re-created fresh.
#
# Preserves:
#   - Ceph storage disks (reused across runs)
#   - Talos ISO (if exists, skipped)
#   - Talos cache file (${PROJECT_ROOT}/.cache/talos-*.qcow2)
#
# Called automatically by startup.sh before the tofu apply step.
# Can also be run standalone: ./cleanup-preflight.sh [--prefix hpa-node]
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TOFU_DIR="${TOFU_DIR:-${SCRIPT_DIR}/../opentofu}"

NODE_PREFIX="${NODE_PREFIX:-hpa-node}"

ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

sudo_password() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    return 0
  fi
  if [ "${SUDO_PASSWORD_PROMPTED:-0}" = "1" ]; then
    die "SUDO_PASSWORD is not set and sudo password prompt was already shown"
  fi
  printf '\n' >&2
  read -r -s -p "Enter sudo password: " SUDO_PASSWORD
  printf '\n' >&2
  SUDO_PASSWORD_PROMPTED=1
  [ -n "${SUDO_PASSWORD:-}" ] || die "SUDO_PASSWORD is required for sudo operations. Set it in .env or enter it when prompted."
}

run_as_root() {
  command -v sudo >/dev/null 2>&1 || die "sudo command not found"
  if sudo -n true &>/dev/null; then
    sudo "$@"
    return $?
  fi
  sudo_password
  if ! printf '%s\n' "${SUDO_PASSWORD}" | sudo -S "$@"; then
    err "sudo command failed; check SUDO_PASSWORD or enter a valid password"
    return 1
  fi
}

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
VOL_NAMES=$(run_as_root virsh vol-list default 2>/dev/null | awk -v pre="${NODE_PREFIX}-" '$1 ~ pre && ($1 ~ /-os\.qcow2$/ || $1 ~ /-os\.raw$/) {print $1}' || true)
if [ -n "${VOL_NAMES}" ]; then
  while IFS= read -r vol; do
    [ -z "${vol}" ] && continue
    log "  Deleting OS volume: ${vol}"
    run_as_root virsh vol-delete --pool default "${vol}" 2>/dev/null || true
  done <<< "${VOL_NAMES}"
  log "  OS volumes removed."
else
  log "  No OS volumes found."
fi

# ---- Step 2b: Remove per-VM ISO clone volumes (recreated by startup.sh) ----
log "Step 2b: Removing per-VM ISO clone volumes..."
CLONE_VOLS=$(run_as_root virsh vol-list default 2>/dev/null | awk -v pre="${NODE_PREFIX}-" '
  $1 ~ pre && $1 ~ /-install\.iso$/ && $1 !~ /^talos-install\.iso$/ {print $1}' || true)
if [ -n "${CLONE_VOLS}" ]; then
  while IFS= read -r vol; do
    [ -z "${vol}" ] && continue
    log "  Deleting ISO clone: ${vol}"
    run_as_root virsh vol-delete --pool default "${vol}" 2>/dev/null || true
  done <<< "${CLONE_VOLS}"
  log "  ISO clones removed."
else
  log "  No ISO clone volumes found."
fi

# ---- Step 3: Check Talos ISO volume (preserve if exists) ------------------
log "Step 3: Checking Talos ISO volume..."
ISO_VOL=$(run_as_root virsh vol-list default 2>/dev/null | awk '/talos-install\.iso/ {print $1}' || true)
if [ -n "${ISO_VOL}" ]; then
  log "  Talos ISO volume '${ISO_VOL}' exists - preserving it"
  SKIP_ISO=true
else
  log "  No Talos ISO volume found - will be downloaded"
  SKIP_ISO=false
fi

# ---- Step 4: Handle Talos base qcow2 volume -------------------------------
# The base volume is created from a cache file by the libvirt provider.
# We remove any stale volume so tofu can recreate it fresh from the cache.
# The cache file at ${PROJECT_ROOT}/.cache/talos-*.qcow2 is preserved.
log "Step 4: Ensuring clean Talos base volume state..."
BASE_VOL=$(run_as_root virsh vol-list default 2>/dev/null | awk '/talos-base\.qcow2/ {print $1}' || true)
if [ -n "${BASE_VOL}" ]; then
  log "  Removing stale talos-base volume (will be recreated from cache)..."
  run_as_root virsh vol-delete --pool default "${BASE_VOL}" 2>/dev/null || true
fi

# Remove from state if present (so tofu can manage it fresh)
for key in $(tofu state list 2>/dev/null | grep "libvirt_volume.talos_base" || true); do
  log "  Removing from state: ${key}"
  tofu state rm "${key}" 2>/dev/null || true
done

print_resource_table() {
  local rows=("$@")
  log "  Resource removal summary:"
  log "  STATUS                         TYPE                         NAME                                           "
  log "  -------                        ---------------------------  ----------------------------------------------- "
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r type name status <<< "${row}"
    printf '  %-25s  %-25s  %-47s\n' "${status}" "${type}" "${name}"
  done
}

remove_tofu_resource() {
  local type="$1"
  local key="$2"
  local status="removed"

  tofu state rm "${key}" >/dev/null 2>&1 || status="not found"
  printf '%s\t%s\t%s\n' "${type}" "${key}" "${status}"
}

# ---- Step 5: Remove stale libvirt resources from tofu state ---------------
log "Step 5: Removing stale libvirt resources from tofu state..."
cd "${TOFU_ABS_DIR}"

removal_rows=()
key=""
row=""
res_type=""

# Always remove VM domains - they need to be created fresh
for key in $(tofu state list 2>/dev/null | grep "libvirt_domain.node" || true); do
  row="$(remove_tofu_resource "libvirt_domain.node" "${key}")" || true
  removal_rows+=("${row}")
done

# OS disks: always remove from state (per-node volumes)
for key in $(tofu state list 2>/dev/null | grep "libvirt_volume.os_disk" || true); do
  row="$(remove_tofu_resource "libvirt_volume.os_disk" "${key}")" || true
  removal_rows+=("${row}")
done

# ISO state: only remove if being re-downloaded (version changed)
if [ "${SKIP_ISO:-false}" = false ]; then
  for key in $(tofu state list 2>/dev/null | grep "libvirt_volume.talos_iso" || true); do
    row="$(remove_tofu_resource "libvirt_volume.talos_iso" "${key}")" || true
    removal_rows+=("${row}")
  done
fi

# Also remove bootstrap/apply resources that depend on fresh VMs
for res_type in talos_machine_configuration_apply talos_machine_bootstrap talos_cluster_kubeconfig; do
  for key in $(tofu state list 2>/dev/null | grep "${res_type}" || true); do
    row="$(remove_tofu_resource "${res_type}" "${key}")" || true
    removal_rows+=("${row}")
  done
done

print_resource_table "${removal_rows[@]}"

# ---- Step 6: Verify Ceph disks are preserved -----------------------------
log "Step 6: Verifying Ceph disks are preserved..."
CEPH_COUNT=$(run_as_root virsh vol-list default 2>/dev/null | awk -v pre="${NODE_PREFIX}-" '$1 ~ pre && $1 ~ /-ceph\.raw$/ {count++} END {print count+0}' || true)
log "  Ceph disks preserved: ${CEPH_COUNT}"

log "=== Pre-flight cleanup complete. Ready for tofu apply. ==="
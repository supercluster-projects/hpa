#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup.sh — Destroy all Talos cluster VMs, volumes, and the hpa-bridge
#              libvirt network, plus local Talos config files.
#
# Iterates through all libvirt domains matching the node_prefix pattern
# (e.g. hpa-node-cp-0, hpa-node-worker-0, etc.), destroys and undefines
# each VM (with --nvram), removes OS and Ceph disk volumes, destroys and
# undefines the hpa-bridge network, and cleans up kubeconfig/talosconfig
# from the provisioning/tofu-libvirt-dev directory.
#
# All paths relative to provisioning/scripts/.
# Usage: ./cleanup.sh [--prefix hpa-node] [--bridge hpa-bridge]
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Defaults (matching provisioning variables) ---------------------------
NODE_PREFIX="${NODE_PREFIX:-hpa-node}"
BRIDGE="${BRIDGE_NAME:-hpa-bridge}"
TOFU_DIR="${TOFU_DIR:-../tofu-libvirt-dev}"

# ---- Parse CLI overrides --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)  NODE_PREFIX="$2"; shift 2 ;;
    --bridge)  BRIDGE="$2";      shift 2 ;;
    --tofu-dir) TOFU_DIR="$2";  shift 2 ;;
    *)         echo "[$(date +%H:%M:%S)] ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

DESTROYED_VMS=0
DESTROYED_VOLS=0
DESTROYED_NETS=0
CLEANED_FILES=0
FAILURES=0

# Resolve TOFU_DIR to an absolute path relative to the script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
TOFU_ABS_DIR="$(cd "${SCRIPT_DIR}/${TOFU_DIR}" &> /dev/null && pwd || echo "${SCRIPT_DIR}/${TOFU_DIR}")"

cleanup_fail() {
  local msg="$1"
  echo "[$(date +%H:%M:%S)] FAIL: ${msg}" >&2
  FAILURES=$((FAILURES + 1))
}

echo "[$(date +%H:%M:%S)] Starting cleanup for node prefix '${NODE_PREFIX}' on bridge '${BRIDGE}'..." >&2

# ---- Step 1: Destroy and undefine all Talos VMs ---------------------------
echo "[$(date +%H:%M:%S)] Looking for libvirt domains matching '${NODE_PREFIX}'..." >&2
VM_NAMES=$(virsh list --name --all 2>/dev/null | grep -E "^${NODE_PREFIX}-(cp|worker)-" || true)

if [[ -z "${VM_NAMES}" ]]; then
  echo "[$(date +%H:%M:%S)] No VMs found matching prefix '${NODE_PREFIX}'." >&2
else
  while IFS= read -r vm; do
    [[ -z "${vm}" ]] && continue
    echo "[$(date +%H:%M:%S)] Destroying VM '${vm}'..." >&2
    if virsh destroy "${vm}" > /dev/null 2>&1; then
      echo "[$(date +%H:%M:%S)]   Destroyed: ${vm}" >&2
    else
      cleanup_fail "virsh destroy '${vm}' (may already be stopped)"
    fi

    echo "[$(date +%H:%M:%S)] Undefining VM '${vm}' (with --nvram)..." >&2
    if virsh undefine --nvram "${vm}" > /dev/null 2>&1; then
      echo "[$(date +%H:%M:%S)]   Undefined: ${vm}" >&2
      DESTROYED_VMS=$((DESTROYED_VMS + 1))
    else
      cleanup_fail "virsh undefine --nvram '${vm}'"
    fi
  done <<< "${VM_NAMES}"
fi

# ---- Step 2: Remove libvirt volumes matching node OS and Ceph disks -------
echo "[$(date +%H:%M:%S)] Looking for libvirt volumes matching '${NODE_PREFIX}'..." >&2
VOL_NAMES=$(virsh vol-list default 2>/dev/null | awk -v prefix="${NODE_PREFIX}-" '$1 ~ prefix {print $1}' || true)

if [[ -z "${VOL_NAMES}" ]]; then
  echo "[$(date +%H:%M:%S)] No volumes found matching prefix '${NODE_PREFIX}'." >&2
else
  while IFS= read -r vol; do
    [[ -z "${vol}" ]] && continue
    echo "[$(date +%H:%M:%S)] Deleting volume '${vol}'..." >&2
    if virsh vol-delete --pool default "${vol}" > /dev/null 2>&1; then
      echo "[$(date +%H:%M:%S)]   Deleted: ${vol}" >&2
      DESTROYED_VOLS=$((DESTROYED_VOLS + 1))
    else
      cleanup_fail "virsh vol-delete '${vol}'"
    fi
  done <<< "${VOL_NAMES}"
fi

# ---- Step 3: Destroy and undefine the hpa-bridge network ------------------
if virsh net-info "${BRIDGE}" > /dev/null 2>&1; then
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' exists. Destroying..." >&2
  if virsh net-destroy "${BRIDGE}" > /dev/null 2>&1; then
    echo "[$(date +%H:%M:%S)]   Network destroyed: ${BRIDGE}" >&2
  else
    cleanup_fail "virsh net-destroy '${BRIDGE}'"
  fi

  if virsh net-undefine "${BRIDGE}" > /dev/null 2>&1; then
    echo "[$(date +%H:%M:%S)]   Network undefined: ${BRIDGE}" >&2
    DESTROYED_NETS=$((DESTROYED_NETS + 1))
  else
    cleanup_fail "virsh net-undefine '${BRIDGE}'"
  fi
else
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' does not exist. Skipping." >&2
fi

# ---- Step 4: Remove kubeconfig and talosconfig if present -----------------
if [[ -d "${TOFU_ABS_DIR}" ]]; then
  for f in kubeconfig talosconfig; do
    fpath="${TOFU_ABS_DIR}/${f}"
    if [[ -f "${fpath}" ]]; then
      rm -f "${fpath}"
      echo "[$(date +%H:%M:%S)]   Removed: ${fpath}" >&2
      CLEANED_FILES=$((CLEANED_FILES + 1))
    fi
  done
else
  echo "[$(date +%H:%M:%S)] Tofu directory '${TOFU_DIR}' not found. Skipping config cleanup." >&2
fi

# ---- Summary --------------------------------------------------------------
echo "========================================" >&2
echo "  Cleanup Summary" >&2
echo "========================================" >&2
echo "  VMs destroyed/undefined:  ${DESTROYED_VMS}" >&2
echo "  Volumes deleted:          ${DESTROYED_VOLS}" >&2
echo "  Networks removed:         ${DESTROYED_NETS}" >&2
echo "  Config files cleaned:     ${CLEANED_FILES}" >&2
echo "  Failures:                 ${FAILURES}" >&2
echo "========================================" >&2

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "[$(date +%H:%M:%S)] Cleanup completed with ${FAILURES} failure(s)." >&2
  exit 1
fi

echo "[$(date +%H:%M:%S)] Cleanup completed successfully." >&2
exit 0

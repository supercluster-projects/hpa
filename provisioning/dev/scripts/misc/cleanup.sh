#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup.sh — Destroy all Talos cluster VMs, volumes, and the hpa-bridge
#              libvirt network, plus local Talos config files.
#
# Iterates through all libvirt domains matching the node_prefix pattern
# (e.g. hpa-node-cp-0, hpa-node-worker-0, etc.), destroys and undefines
# each VM (with --nvram), removes OS and Ceph disk volumes, destroys and
# undefines the hpa-bridge network, and cleans up kubeconfig/talosconfig
# from the provisioning/dev directory.
#
# All paths relative to provisioning/dev/scripts/.
# Usage: ./cleanup.sh [--prefix hpa-node] [--bridge hpa-bridge]
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Defaults (matching provisioning variables) ---------------------------
NODE_PREFIX="${NODE_PREFIX:-hpa-node}"
BRIDGE="${BRIDGE_NAME:-hpa-bridge}"
TOFU_DIR="${TOFU_DIR:-../opentofu}"
PRESERVE_CEPH="${PRESERVE_CEPH:-true}"  # Preserve Ceph disks by default

# ---- Parse CLI overrides --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)  NODE_PREFIX="$2"; shift 2 ;;
    --bridge)  BRIDGE="$2";      shift 2 ;;
    --tofu-dir) TOFU_DIR="$2";  shift 2 ;;
    --preserve-ceph) PRESERVE_CEPH="true"; shift ;;
    --reset-ceph)   PRESERVE_CEPH="false"; shift ;;
    *)         echo "[$(date '+%H:%M:%S')] ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

DESTROYED_VMS=0
DESTROYED_VOLS=0
DESTROYED_NETS=0
CLEANED_FILES=0
FAILURES=0

# Resolve TOFU_DIR to an absolute path relative to the script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

sudo_password() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    return 0
  fi
  if [ "${SUDO_PASSWORD_PROMPTED:-0}" = "1" ]; then
    cleanup_fail "SUDO_PASSWORD is not set and sudo password prompt was already shown"
    return 1
  fi
  printf '\n' >&2
  read -r -s -p "Enter sudo password: " SUDO_PASSWORD
  printf '\n' >&2
  SUDO_PASSWORD_PROMPTED=1
  [ -n "${SUDO_PASSWORD:-}" ] || { cleanup_fail "SUDO_PASSWORD is required for sudo operations"; return 1; }
}

run_as_root() {
  command -v sudo >/dev/null 2>&1 || { cleanup_fail "sudo command not found"; return 1; }
  if sudo -n true &>/dev/null; then
    sudo "$@"
    return $?
  fi
  sudo_password || return 1
  if ! printf '%s\n' "${SUDO_PASSWORD}" | sudo -S "$@"; then
    cleanup_fail "sudo command failed; check SUDO_PASSWORD or enter a valid password"
    return 1
  fi
}

TOFU_ABS_DIR="$(cd "${SCRIPT_DIR}/${TOFU_DIR}" &> /dev/null && pwd || echo "${SCRIPT_DIR}/${TOFU_DIR}")"
CURRENT_TS="$(date '+%H:%M:%S')"

cleanup_fail() {
  local msg="$1"
  echo "[$CURRENT_TS] FAIL: ${msg}" >&2
  FAILURES=$((FAILURES + 1))
}

print_cleanup_banner() {
  echo -e "\r\033[K[$CURRENT_TS] Starting cleanup for node prefix '${NODE_PREFIX}' on bridge '${BRIDGE}'..." >&2
  printf "  %-24s %-32s %-12s\n" "STAGE" "TARGET" "STATUS" >&2
  printf "  %-24s %-32s %-12s\n" "-----" "------" "------" >&2
}

update_cleanup_status() {
  local stage="$1"
  local target="$2"
  local status="$3"

  echo -e "\r\033[K[$CURRENT_TS] Starting cleanup for node prefix '${NODE_PREFIX}' on bridge '${BRIDGE}'..." >&2
  printf "  %-24s %-32s %-12s\n" "${stage}" "${target}" "${status}" >&2
}

print_summary_table() {
  echo "========================================" >&2
  echo "  Cleanup Summary" >&2
  echo "========================================" >&2
  printf "  %-24s %-32s %-12s\n" "ITEM" "VALUE" "STATUS" >&2
  printf "  %-24s %-32s %-12s\n" "----" "-----" "------" >&2
  printf "  %-24s %-32s %-12s\n" "VMs destroyed/undefined" "${DESTROYED_VMS}" "OK" >&2
  printf "  %-24s %-32s %-12s\n" "Volumes deleted" "${DESTROYED_VOLS}" "OK" >&2
  printf "  %-24s %-32s %-12s\n" "Networks removed" "${DESTROYED_NETS}" "OK" >&2
  printf "  %-24s %-32s %-12s\n" "Config files cleaned" "${CLEANED_FILES}" "OK" >&2
  printf "  %-24s %-32s %-12s\n" "Failures" "${FAILURES}" "${FAILURES:-0}" >&2
  echo "========================================" >&2
}

print_cleanup_banner

# ---- Step 1: Destroy and undefine all Talos VMs ---------------------------
update_cleanup_status "VM discovery" "${VM_NAMES:-none}" "scanning"
VM_NAMES=$(virsh -c qemu:///system list --name --all 2>/dev/null | grep -E "^${NODE_PREFIX}-(cp|worker)-" || true)
if [[ -z "${VM_NAMES}" ]]; then
  update_cleanup_status "VM cleanup" "none" "not found"
else
  while IFS= read -r vm; do
    [[ -z "${vm}" ]] && continue
    update_cleanup_status "VM destroy" "${vm}" "running"
    if virsh -c qemu:///system destroy "${vm}" > /dev/null 2>&1; then
      update_cleanup_status "VM undefine" "${vm}" "destroyed"
    else
      cleanup_fail "virsh -c qemu:///system destroy '${vm}' (may already be stopped)"
      update_cleanup_status "VM destroy" "${vm}" "failed"
      continue
    fi

    update_cleanup_status "VM undefine" "${vm}" "undefining"
    if virsh -c qemu:///system undefine --nvram "${vm}" > /dev/null 2>&1; then
      update_cleanup_status "VM undefine" "${vm}" "undefined"
      DESTROYED_VMS=$((DESTROYED_VMS + 1))
    else
      cleanup_fail "virsh -c qemu:///system undefine --nvram '${vm}'"
      update_cleanup_status "VM undefine" "${vm}" "failed"
    fi
  done <<< "${VM_NAMES}"
fi

# ---- Step 2: Remove libvirt volumes matching node OS and Ceph disks -------
update_cleanup_status "Volume discovery" "${VOL_NAMES:-none}" "scanning"
VOL_NAMES=$(virsh -c qemu:///system vol-list default 2>/dev/null | awk -v prefix="${NODE_PREFIX}-" '$1 ~ prefix {print $1}' || true)
if [[ -z "${VOL_NAMES}" ]]; then
  update_cleanup_status "Volume cleanup" "none" "not found"
else
  while IFS= read -r vol; do
    [[ -z "${vol}" ]] && continue
    update_cleanup_status "Volume delete" "${vol}" "deleting"
    if virsh -c qemu:///system vol-delete --pool default "${vol}" > /dev/null 2>&1; then
      update_cleanup_status "Volume delete" "${vol}" "deleted"
      DESTROYED_VOLS=$((DESTROYED_VOLS + 1))
    else
      cleanup_fail "virsh -c qemu:///system vol-delete '${vol}'"
      update_cleanup_status "Volume delete" "${vol}" "failed"
    fi
  done <<< "${VOL_NAMES}"
fi

# Ceph disk handling - preserve by default for idempotent cluster recreation
if [ "${PRESERVE_CEPH}" = "false" ]; then
  update_cleanup_status "Ceph disks" "clear" "deleting"
  if run_as_root rm -rf /var/lib/libvirt/images/ceph-disks/*.img; then
    update_cleanup_status "Ceph disks" "clear" "cleared"
  else
    cleanup_fail "rm -rf /var/lib/libvirt/images/ceph-disks/*.img"
    update_cleanup_status "Ceph disks" "clear" "failed"
  fi
else
  update_cleanup_status "Ceph disks" "preserve" "preserved"
fi

# ---- Step 3: Destroy and undefine the hpa-bridge network ------------------
if virsh -c qemu:///system net-info "${BRIDGE}" > /dev/null 2>&1; then
  update_cleanup_status "Bridge cleanup" "${BRIDGE}" "destroying"
  if virsh -c qemu:///system net-destroy "${BRIDGE}" > /dev/null 2>&1; then
    update_cleanup_status "Bridge cleanup" "${BRIDGE}" "destroyed"
  else
    cleanup_fail "virsh -c qemu:///system net-destroy '${BRIDGE}'"
    update_cleanup_status "Bridge cleanup" "${BRIDGE}" "failed"
  fi

  update_cleanup_status "Bridge cleanup" "${BRIDGE}" "undefining"
  if virsh -c qemu:///system net-undefine "${BRIDGE}" > /dev/null 2>&1; then
    update_cleanup_status "Bridge cleanup" "${BRIDGE}" "undefined"
    DESTROYED_NETS=$((DESTROYED_NETS + 1))
  else
    cleanup_fail "virsh -c qemu:///system net-undefine '${BRIDGE}'"
    update_cleanup_status "Bridge cleanup" "${BRIDGE}" "failed"
  fi
else
  update_cleanup_status "Bridge cleanup" "${BRIDGE}" "skipped"
fi

# ---- Step 4: Remove kubeconfig and talosconfig if present -----------------
if [[ -d "${TOFU_ABS_DIR}" ]]; then
  for f in kubeconfig talosconfig; do
    fpath="${TOFU_ABS_DIR}/${f}"
    if [[ -f "${fpath}" ]]; then
      update_cleanup_status "Config cleanup" "${f}" "removing"
      if rm -f "${fpath}"; then
        update_cleanup_status "Config cleanup" "${f}" "removed"
        CLEANED_FILES=$((CLEANED_FILES + 1))
      else
        cleanup_fail "rm -f '${fpath}'"
        update_cleanup_status "Config cleanup" "${f}" "failed"
      fi
    else
      update_cleanup_status "Config cleanup" "${f}" "not found"
    fi
  done
else
  update_cleanup_status "Config cleanup" "${TOFU_DIR}" "skipped"
fi

print_summary_table

if [[ "${FAILURES}" -gt 0 ]]; then
  update_cleanup_status "Cleanup" "failed" "${FAILURES} failure(s)"
  exit 1
fi

update_cleanup_status "Cleanup" "complete" "success"
exit 0

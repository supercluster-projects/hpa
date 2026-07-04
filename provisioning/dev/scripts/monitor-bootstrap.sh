#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# monitor-bootstrap.sh — Real-time Talos bootstrap progress display
#
# Polls actual Talos API state (nc), disk installation (qemu-img progress),
# and talosctl services/staticpods to show real progress during tofu apply.
#
# Writes a single status line to a shared file (MONITOR_STATUS_FILE from
# preamble.sh). The table_redraw poller in startup.sh reads this file every
# 5 seconds and includes the status line below the progress table on fd 3.
#
# Usage: monitor-bootstrap.sh <cp-ip> <os-disk> <kubeconfig-path>
#
#   <cp-ip>           Control plane IP (e.g. 192.168.122.100)
#   <os-disk>         Path to OS disk qcow2 for disk growth monitoring
#   <kubeconfig-path> Kubeconfig path; monitor exits with 0 when found
#
# Exit: 0 on completion, 1 on timeout (20 min)
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

CP_IP="${1:?Usage: monitor-bootstrap.sh <cp-ip> <os-disk> <kubeconfig-path>}"
OS_DISK="${2:?}"
KUBECONFIG_PATH="${3:?}"

STATUS_FILE="${MONITOR_STATUS_FILE:-${PROJECT_ROOT}/.gsd/bootstrap-monitor-status}"
mkdir -p "$(dirname "${STATUS_FILE}")"

# Mark status file as active
echo "booting" > "${STATUS_FILE}"

TIMEOUT_SEC=1200  # 20 min — matches tofu's talos_machine_bootstrap timeout
START_TS=$(date +%s)

# Phase tracking
phase_booting=false
phase_installing=false
phase_rebooting=false
phase_running=false

# Helper: extract talosconfig from tofu state (best-effort)
TOFUDIR="${PROJECT_ROOT}/provisioning/dev/opentofu"

extract_talosconfig() {
  local target="$1"
  if [ ! -d "${TOFUDIR}" ]; then return 1; fi
  if ! command -v tofu >/dev/null 2>&1; then return 1; fi
  local raw
  raw=$(cd "${TOFUDIR}" && tofu show -json 2>/dev/null | jq -r '
    .values.root_module.resources[] |
    select(.address == "data.talos_client_configuration.this") |
    .values.talos_config
  ' 2>/dev/null) || return 1
  if [ -z "${raw}" ] || [ "${raw}" = "null" ]; then return 1; fi
  echo "${raw}" > "${target}"
}

# ---- Main loop ------------------------------------------------------------
while true; do
  elapsed=$(( $(date +%s) - START_TS ))
  if [ "${elapsed}" -gt "${TIMEOUT_SEC}" ]; then
    echo "timeout after ${elapsed}s" > "${STATUS_FILE}"
    exit 1
  fi

  # Early exit: kubeconfig appeared
  if [ -f "${KUBECONFIG_PATH}" ] && [ -s "${KUBECONFIG_PATH}" ]; then
    echo "kubeconfig ready! [${elapsed}s]" > "${STATUS_FILE}"
    exit 0
  fi

  # ---- Signal A: Disk growth -------------------------------------------
  disk_info=$(sudo qemu-img info --force-share "${OS_DISK}" 2>/dev/null) || disk_info=""
  disk_size=$(echo "${disk_info}" | sed -n 's/disk size: //p')
  disk_size_bytes=$(echo "${disk_info}" | grep "disk size" | grep -oP '\d+(?= bytes)' | head -1)
  virt_size_bytes=$(echo "${disk_info}" | grep "virtual size" | grep -oP '\d+(?= bytes)' | head -1)

  disk_pct=""
  if [ -n "${disk_size_bytes}" ] && [ -n "${virt_size_bytes}" ] && [ "${virt_size_bytes}" -gt 0 ] 2>/dev/null; then
    disk_pct="$(( disk_size_bytes * 100 / virt_size_bytes ))%"
  fi

  if [ -n "${disk_size}" ] && [ "${disk_size}" != "0 B" ]; then
    phase_installing=true
    disk_part="${disk_size}${disk_pct:+ (${disk_pct})}"
  else
    disk_part=""
  fi

  # ---- Signal B: Talos API reachability ---------------------------------
  api_up=false
  if nc -z -w1 "${CP_IP}" 50000 2>/dev/null; then
    api_up=true
    phase_booting=true
  else
    if [ "${phase_booting}" = true ] && [ "${phase_running}" = false ]; then
      phase_rebooting=true
      phase_installing=false
    fi
  fi

  # ---- Signal C: talosctl services --------------------------------------
  svc_etcd=""; svc_kubelet=""; svc_apiserver=""
  TMPCFG=$(mktemp /tmp/talos-monitor-XXXX)
  if extract_talosconfig "${TMPCFG}"; then
    services_out=$(talosctl -n "${CP_IP}" --talosconfig "${TMPCFG}" services 2>/dev/null) || services_out=""
    if [ -n "${services_out}" ]; then
      phase_running=true
      phase_rebooting=false
      svc_etcd=$(echo "${services_out}" | awk '/^etcd /{print $2}')
      svc_kubelet=$(echo "${services_out}" | awk '/^kubelet /{print $2}')
      pods_out=$(talosctl -n "${CP_IP}" --talosconfig "${TMPCFG}" get staticpods 2>/dev/null) || pods_out=""
      svc_apiserver=$(echo "${pods_out}" | awk '/kube-apiserver/{print $2; exit}')
    fi
  fi
  rm -f "${TMPCFG}"

  # ---- Build status line -------------------------------------------------
  parts=()
  if [ "${phase_installing}" = true ] && [ -n "${disk_part}" ]; then
    parts+=("installing ${disk_part}")
  elif [ "${phase_rebooting}" = true ]; then
    parts+=("rebooting")
  elif [ "${phase_running}" = true ]; then
    parts+=("running")
  else
    parts+=("booting")
  fi

  if [ "${api_up}" = true ]; then
    parts+=("api:up")
  fi

  if [ -n "${svc_etcd}" ]; then
    parts+=("etcd:${svc_etcd}")
  fi
  if [ -n "${svc_kubelet}" ]; then
    parts+=("kubelet:${svc_kubelet}")
  fi
  if [ -n "${svc_apiserver}" ]; then
    parts+=("apiserver:${svc_apiserver}")
  fi

  parts+=("[${elapsed}s]")

  # Write as single line to shared status file
  # Build status line — join array elements with spaces
  local status_line=""
  local p
  for p in "${parts[@]}"; do
    if [ -z "${status_line}" ]; then
      status_line="${p}"
    else
      status_line="${status_line} ${p}"
    fi
  done
  echo "${status_line}" > "${STATUS_FILE}"

  sleep 5
done

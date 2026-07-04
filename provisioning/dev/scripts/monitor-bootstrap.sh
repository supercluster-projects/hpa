#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# monitor-bootstrap.sh — Real-time Talos bootstrap progress display
#
# Polls actual Talos API state (nc), disk installation (qemu-img progress),
# and talosctl services/staticpods to show real progress during tofu apply.
#
# Writes ONE UPDATING LINE to fd 3 (saved terminal fd, bypassing the
# startup.sh tee redirect) so that progress lines REPLACE each other on
# screen and do NOT accumulate in startup.log.
#
# Usage: monitor-bootstrap.sh <cp-ip> <os-disk> <kubeconfig-path>
#
#   <cp-ip>           Control plane IP (e.g. 192.168.122.100)
#   <os-disk>         Path to OS disk qcow2 for disk growth monitoring
#   <kubeconfig-path> Kubeconfig path; monitor exits with 0 when found
#
# Exit: 0 on completion, 1 on timeout (15 min), 2 on usage error
# ---------------------------------------------------------------------------
set -euo pipefail

CP_IP="${1:?Usage: monitor-bootstrap.sh <cp-ip> <os-disk> <kubeconfig-path>}"
OS_DISK="${2:?}"
KUBECONFIG_PATH="${3:?}"

# ---- fd 3: raw terminal (saved by startup.sh before tee redirect) --------
# startup.sh runs `exec 3>&2` just before `exec > >(tee ...) 2>&1`, so fd 3
# points directly at the original terminal. Writing \r-based lines here
# means they REPLACE each other on screen without accumulating in the log.
TTY_FD=3
if [ ! -t "${TTY_FD}" ]; then
  # Fallback: manual invocation or no fd 3 available
  if [ -c /dev/tty ]; then
    TTY_FD="/dev/tty"
  else
    TTY_FD=2  # last resort, goes through tee into log
    echo "(bootstrap monitor progress will appear in startup.log" >&2
    echo " — try piping through startup.sh)" >&2
  fi
fi

progress()   { printf "\r\e[2K%b" "$*" >"${TTY_FD}"; }
progress_nl() { printf "\n" >"${TTY_FD}"; }
trap progress_nl EXIT  # release cursor on exit

# ---- Timeout --------------------------------------------------------------
TIMEOUT_SEC=1200  # 20 min — matches tofu's talos_machine_bootstrap timeout
START_TS=$(date +%s)

# ---- Phase tracking -------------------------------------------------------
phase_booting=false
phase_installing=false
phase_rebooting=false
phase_running=false

# ---- Helper: extract talosconfig from tofu state (best-effort) -----------
# Uses PROJECT_ROOT from preamble.sh, or defaults to the standard layout.
TOFUDIR="${PROJECT_ROOT:-/home/cores/Documents/Projects/Study/HPA/with-gsd}/provisioning/dev/opentofu"

extract_talosconfig() {
  local target="$1"
  if [ ! -d "${TOFUDIR}" ]; then
    return 1
  fi
  if ! command -v tofu >/dev/null 2>&1; then
    return 1
  fi
  local raw
  raw=$(cd "${TOFUDIR}" && tofu show -json 2>/dev/null | jq -r '
    .values.root_module.resources[] |
    select(.address == "data.talos_client_configuration.this") |
    .values.talos_config
  ' 2>/dev/null) || return 1
  if [ -z "${raw}" ] || [ "${raw}" = "null" ]; then
    return 1
  fi
  echo "${raw}" > "${target}"
}

# ---- Main loop ------------------------------------------------------------
while true; do
  elapsed=$(( $(date +%s) - START_TS ))
  if [ "${elapsed}" -gt "${TIMEOUT_SEC}" ]; then
    progress "\e[1;31m[bootstrap] TIMEOUT after ${elapsed}s — bootstrap did not complete\e[0m"
    exit 1
  fi

  # Early exit: kubeconfig appeared
  if [ -f "${KUBECONFIG_PATH}" ] && [ -s "${KUBECONFIG_PATH}" ]; then
    progress "\e[1;32m[bootstrap] kubeconfig ready! [${elapsed}s]\e[0m"
    exit 0
  fi

  # ---- Signal A: Disk growth (installation progress) ----------------------
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
    disk_label="\e[33m${disk_size}"
    [ -n "${disk_pct}" ] && disk_label="${disk_label} (${disk_pct})"
    disk_label="${disk_label}\e[0m"
  else
    disk_label="\e[90mwaiting for disk\e[0m"
  fi

  # ---- Signal B: Talos API reachability -----------------------------------
  if nc -z -w1 "${CP_IP}" 50000 2>/dev/null; then
    api_label="\e[32mapi:connected\e[0m"
    phase_booting=true
  else
    if [ "${phase_booting}" = true ] && [ "${phase_running}" = false ]; then
      # Was reachable, now gone after API → likely reboot during install
      phase_rebooting=true
      phase_installing=false
    fi
    api_label="\e[90mapi:waiting\e[0m"
  fi

  # ---- Signal C: talosctl services (rich cluster state) -------------------
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

  # ---- Build the single status line ---------------------------------------
  seg="\e[90m[${elapsed}s]\e[0m"

  if [ "${phase_installing}" = true ]; then
    seg="${seg} \e[33mInstalling\e[0m ${disk_label}"
  elif [ "${phase_rebooting}" = true ]; then
    seg="${seg} \e[33mRebooting (install done)\e[0m"
  elif [ "${phase_running}" = true ]; then
    seg="${seg} \e[32mRunning (disk)\e[0m"
  else
    seg="${seg} \e[90mBooting ISO\e[0m"
  fi

  seg="${seg} ${api_label}"

  if [ -n "${svc_etcd}" ]; then
    if [ "${svc_etcd}" = "Running" ]; then
      seg="${seg} \e[32metcd:${svc_etcd}\e[0m"
    else
      seg="${seg} \e[33metcd:${svc_etcd}\e[0m"
    fi
  fi
  if [ -n "${svc_kubelet}" ]; then
    [ "${svc_kubelet}" = "Running" ] && c=32 || c=33
    seg="${seg} \e[${c}mkubelet:${svc_kubelet}\e[0m"
  fi
  if [ -n "${svc_apiserver}" ]; then
    seg="${seg} \e[36mAPIserver:${svc_apiserver}\e[0m"
  fi

  progress "${seg}"
  sleep 5
done

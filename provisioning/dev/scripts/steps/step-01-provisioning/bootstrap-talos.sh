#!/usr/bin/env bash
# Bootstrap Talos cluster (Method 1: insecure)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../misc/preamble.sh"

get_node_cidr_prefix() {
  local cidr="${1:-${DEV_CIDR_BLOCK:-192.168.122.0/24}}"
  local ip="${cidr%%/*}"
  ip="$(printf '%s' "${ip}" | awk -F. '{print $1 "." $2 "." $3}')"
  printf '%s.' "${ip}"
}

get_node_ips() {
  local prefix="$(get_node_cidr_prefix)"
  local cp_count="${DEV_CP_COUNT:-1}"
  local worker_count="${DEV_WORKER_COUNT:-3}"
  local start
  local end

  start=100
  end=$((100 + cp_count - 1))
  for start in $(seq 100 $end); do
    printf '%s%s\n' "${prefix}" "${start}"
  done

  start=110
  end=$((110 + worker_count - 1))
  for start in $(seq 110 $end); do
    printf '%s%s\n' "${prefix}" "${start}"
  done
}

get_talos_machine_json() {
  talosctl --talosconfig "${TALOSCONFIG}" get machines -o json 2>/dev/null || true
}

get_talos_phase() {
  local ip="$1"
  local machine

  machine="$(get_talos_machine_json | jq -r --arg ip "${ip}" '
    (.items[]? // []) as $items
    | $items[]?
    | select(
        (.metadata.labels["talos.dev/machine-ip"] // "") == $ip
        or (.metadata.name == ($ip | gsub("\\."; "-")))
        or (.status.machineStatus.ip // .status.machineStatus.nodeIP // "") == $ip
      )
    | (.status.phase // .status.machineStatus.phase // "")
  ' | head -1)"
  printf '%s' "${machine:-waiting}"
}

get_talos_ready() {
  local ip="$1"
  local ready

  ready="$(get_talos_machine_json | jq -r --arg ip "${ip}" '
    (.items[]? // []) as $items
    | $items[]?
    | select(
        (.metadata.labels["talos.dev/machine-ip"] == $ip)
        or (.metadata.name == ($ip | gsub("\\."; "-")))
        or (.status.machineStatus.ip // .status.machineStatus.nodeIP // "") == $ip
      )
    | .status.conditions[]?
    | select(.type == "Ready")
    | .status
  ' | head -1)"
  printf '%s' "${ready:-unknown}"
}

get_talos_services() {
  local ip="$1"
  local services

  services="$(talosctl --talosconfig "${TALOSCONFIG}" service --nodes "${ip}" 2>/dev/null \
    | awk 'NR > 1 && NF && $1 !~ /^-$/ {svc=$1; sub(/=.*/, "", svc); status=$2; if (status == "Running") running = running svc "=" status " "; else failed = failed svc "=" status " "} END {printf "%s%s", running, failed}' \
    | tr -s ' ' | sed 's/^ //; s/ $//')"

  if [ -z "${services}" ]; then
    printf 'waiting'
  else
    printf '%s' "${services}"
  fi
}

print_bootstrap_status_table() {
  local progress="${1:-}"

  echo -e "\r\033[K" >&3
  echo "  Talos bootstrap node progress${progress:+ (${progress})}:" >&3
  echo "  VM/Node                           VM state    Ready   Phase        Services" >&3
  echo "  --------------------------------  ----------  ------  -----------  --------------------------------------------" >&3

  local found=false
  local ip
  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue
    found=true
    local vm="${ip//./-}"
    local vm_state="unknown"
    local phase
    local ready
    local services

    if [ -n "$(virsh -c qemu:///system dominfo "${vm}" 2>/dev/null)" ]; then
      vm_state="$(virsh -c qemu:///system domstate "${vm}" 2>/dev/null || echo unknown)"
    fi

    phase="$(get_talos_phase "${ip}")"
    ready="$(get_talos_ready "${ip}")"
    services="$(get_talos_services "${ip}")"

    [ -z "${phase}" ] && phase="waiting"
    [ -z "${ready}" ] && ready="unknown"
    [ -z "${services}" ] && services="waiting"

    printf '  %-32s  %-10s  %-5s  %-11s  %s\n' "${vm} (${ip})" "${vm_state}" "${ready}" "${phase}" "${services}" >&3
  done < <(get_node_ips)

  if [ "${found}" = false ]; then
    echo "  No Talos VMs detected yet." >&3
  fi
}

main() {
  echo ">>> Bootstrapping Talos cluster (Method 1: insecure)..." >&3
  
  # Get Talos endpoint
  PRIMARY_CP_IP="${PRIMARY_CP_IP:-192.168.122.100}"
  
  BOOTSTRAP_ENDPOINT="insecure://${PRIMARY_CP_IP}"
  
  # Set talosconfig path
  export TALOSCONFIG="${DEV_TOFU_DIR:-${SCRIPT_DIR}/../opentofu}/talosconfig"
  
  # Check for talosctl
  if ! command -v talosctl &>/dev/null; then
    echo "WARNING: talosctl not found, skipping bootstrap" >&2
    return 0
  fi
  
  # Set endpoint using insecure scheme (Method 1)
  log_step "Setting Talos endpoint to ${BOOTSTRAP_ENDPOINT}"
  talosctl --talosconfig "${TALOSCONFIG}" config endpoint "${BOOTSTRAP_ENDPOINT}"
  talosctl --talosconfig "${TALOSCONFIG}" config node "${PRIMARY_CP_IP}"
  
  # Bootstrap using insecure scheme (Method 1)
  log_step "Running talosctl bootstrap (${BOOTSTRAP_ENDPOINT})..."
  if timeout 120 talosctl --talosconfig "${TALOSCONFIG}" bootstrap --nodes "${PRIMARY_CP_IP}" --endpoints "${BOOTSTRAP_ENDPOINT}" 2>&1 | tee -a "${STARTUP_LOG}"; then
    log_step "Bootstrap completed successfully"
  else
    log_step "WARNING: Bootstrap returned non-zero, continuing..."
  fi
  
  # Wait for API endpoint to be available
  log_step "Waiting for Talos API to be available..."
  API_READY=false
  for i in {1..30}; do
    if timeout 5 curl -sk "https://${PRIMARY_CP_IP}:6443/healthz" 2>/dev/null | grep -q "ok"; then
      API_READY=true
      print_bootstrap_status_table "API available"
      break
    fi
    print_bootstrap_status_table "Waiting for API... (${i}/30)"
    sleep 5
  done
  
  if [ "$API_READY" = true ]; then
    log_step "Talos API is available"
    
    # Extract kubeconfig after successful bootstrap
    log_step "Extracting kubeconfig after bootstrap..."
    if [ -f "${TALOSCONFIG:-}" ]; then
      if talosctl --talosconfig "${TALOSCONFIG}" kubeconfig . 2>/dev/null; then
        [ -f ./kubeconfig ] && cp ./kubeconfig "${KUBECONFIG}"
        log_step "Kubeconfig updated via talosctl"
      fi
    fi
  else
    log_step "WARNING: Talos API not available after bootstrap timeout"
  fi
  
  echo ">>> Talos bootstrap complete" >&3
}

main "$@"

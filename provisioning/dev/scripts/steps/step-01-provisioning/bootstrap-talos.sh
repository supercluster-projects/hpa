#!/usr/bin/env bash
# Bootstrap Talos cluster (Method 1: insecure)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../misc/preamble.sh"

main() {
  echo ">>> Bootstrapping Talos cluster (Method 1: insecure)..." >&3
  
  # Get Talos endpoint
  PRIMARY_CP_IP="${PRIMARY_CP_IP:-192.168.122.100}"
  
  # Set talosconfig path
  export TALOSCONFIG="${DEV_TOFU_DIR:-${SCRIPT_DIR}/../opentofu}/talosconfig"
  
  # Check for talosctl
  if ! command -v talosctl &>/dev/null; then
    echo "WARNING: talosctl not found, skipping bootstrap" >&2
    return 0
  fi
  
  # Set endpoint using insecure scheme (Method 1)
  log_step "Setting Talos endpoint to insecure://${PRIMARY_CP_IP}"
  talosctl --talosconfig "${TALOSCONFIG}" config endpoint "insecure://${PRIMARY_CP_IP}" 2>/dev/null || true
  talosctl --talosconfig "${TALOSCONFIG}" config node "${PRIMARY_CP_IP}" 2>/dev/null || true
  
  # Bootstrap using insecure scheme (Method 1)
  log_step "Running talosctl bootstrap (insecure://${PRIMARY_CP_IP})..."
  if timeout 120 talosctl --talosconfig "${TALOSCONFIG}" bootstrap -n "${PRIMARY_CP_IP}" 2>&1 | tee -a "${STARTUP_LOG}"; then
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
      break
    fi
    printf '\r\033[KWaiting for API... (%d/30)' "${i}"
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

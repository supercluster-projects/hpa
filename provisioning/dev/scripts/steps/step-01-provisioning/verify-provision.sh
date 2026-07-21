#!/usr/bin/env bash
# Verify OpenTofu provisioning and cluster readiness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../misc/preamble.sh"

main() {
  echo ">>> Verifying OpenTofu provisioning..." >&3
  
  local errors=0
  
  # Check OpenTofu state
  if [ -f "${DEV_TOFU_DIR:-${SCRIPT_DIR}/../opentofu}/terraform.tfstate" ]; then
    echo "✓ OpenTofu state file exists"
  else
    echo "✗ OpenTofu state file not found"
    errors=$((errors + 1))
  fi
  
  # Check kubeconfig
  local kubeconfig_candidate="${KUBECONFIG:-${DEV_TOFU_DIR:-${SCRIPT_DIR}/../opentofu}/kubeconfig}"
  if [ -f "${kubeconfig_candidate}" ]; then
    echo "✓ Kubeconfig exists: ${kubeconfig_candidate}"
  elif [ -f "${PROJECT_ROOT}/kubeconfig" ]; then
    kubeconfig_candidate="${PROJECT_ROOT}/kubeconfig"
    echo "✓ Kubeconfig exists: ${kubeconfig_candidate}"
  else
    echo "✗ Kubeconfig not found at ${kubeconfig_candidate}"
    errors=$((errors + 1))
  fi

  # Check talosconfig
  if [ -f "${DEV_TOFU_DIR:-${SCRIPT_DIR}/../opentofu}/talosconfig" ]; then
    echo "✓ Talosconfig exists"
  else
    echo "✗ Talosconfig not found"
  fi
  
  # Check cluster health
  if command -v kubectl &>/dev/null; then
    NODE_COUNT=0
    for _ in $(seq 1 60); do
      set +e
      NODE_COUNT="$(kubectl get nodes --kubeconfig="${kubeconfig_candidate}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')"
      set -e
      if [ "${NODE_COUNT}" -gt 0 ]; then
        break
      fi
      sleep 10
    done
    NODE_COUNT="${NODE_COUNT:-0}"
    if [ "${NODE_COUNT}" -gt 0 ]; then
      echo "     Nodes ready: ${NODE_COUNT}"
      
      # Verify all nodes are Ready
      if kubectl get nodes --kubeconfig="${kubeconfig_candidate}" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
        echo "✓ All nodes are Ready"
      else
        echo "⚠ Some nodes not Ready"
      fi
    else
      echo "✗ No nodes found in cluster"
      errors=$((errors + 1))
    fi
  fi
  
  if [ ${errors} -gt 0 ]; then
    return 1
  fi
  
  return 0
}

main "$@"

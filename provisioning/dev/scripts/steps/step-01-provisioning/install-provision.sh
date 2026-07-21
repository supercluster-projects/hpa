#!/usr/bin/env bash
# Install OpenTofu provisioning + bootstrap Talos cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../misc/preamble.sh"

main() {
  echo ">>> Step 01: Running OpenTofu apply..." >&3
  
  # Get absolute path
  TFDIR="$(cd "${DEV_TOFU_DIR:-${SCRIPT_DIR}/../opentofu}" 2>/dev/null && pwd)"
  if [ -z "${TFDIR}" ]; then
    echo "ERROR: OpenTofu directory not found" >&2
    exit 1
  fi
  
  # Check OpenTofu availability
  if ! command -v tofu &>/dev/null; then
    echo "ERROR: OpenTofu (tofu) not found in PATH" >&2
    exit 1
  fi
  
  # Init OpenTofu (backend false for local runs)
  log_step "Running tofu init..."
  (cd "${TFDIR}" && tofu init -backend=false) 2>&1 | grep -E "✓|Successfully|Error|warning" || true
  
  # Verify libvirtd
  if ! virsh -c qemu:///system list &>/dev/null; then
    die "libvirtd is not reachable via 'virsh list'. Ensure libvirld is running."
  fi
  
  # Pre-flight cleanup
  CLEANUP_ARGS="--prefix ${DEV_NODE_PREFIX:-hpa-node} --tofu-dir ${TFDIR}"
  if [ "${RESET_CEPH:-false}" = true ]; then
    CLEANUP_ARGS="${CLEANUP_ARGS} --reset-ceph"
  fi
  log_step "Running pre-flight cleanup..."
  bash "${MISC_DIR}/cleanup-preflight.sh" ${CLEANUP_ARGS} 2>&1 || log_step "Pre-flight cleanup warnings"
  
  # Generate variables file for OpenTofu
  TMP_VARS="${TFDIR}/dev.auto.tfvars"
  log_step "Generating ${TMP_VARS}..."
  {
    for var_name in DEV_CLUSTER_NAME DEV_CP_COUNT DEV_WORKER_COUNT DEV_VM_CPU \
                    DEV_CP_RAM_MB DEV_WORKER_RAM_MB DEV_OS_DISK_SIZE_GB \
                    DEV_CEPH_DISK_SIZE_GB DEV_BRIDGE_NAME DEV_NODE_PREFIX \
                    DEV_CIDR_BLOCK TALOS_VERSION; do
      val="${!var_name:-}"
      [ -z "${val}" ] && continue
      case "$var_name" in
        DEV_CP_COUNT|DEV_WORKER_COUNT|DEV_VM_CPU|DEV_CP_RAM_MB|DEV_WORKER_RAM_MB|DEV_OS_DISK_SIZE_GB|DEV_CEPH_DISK_SIZE_GB)
          echo "${var_name} = ${val}"
          ;;
        *)
          echo "${var_name} = \"${val}\""
          ;;
      esac
    done
  } > "${TMP_VARS}"
  
  # Run OpenTofu apply
  log_step "Running tofu apply -auto-approve..."
  (cd "${TFDIR}" && tofu apply -auto-approve 2>&1 | tee -a "${PROJECT_ROOT}/.tofu-apply.log") &
  TOFU_PID=$!
  
  # Monitor progress
  while kill -0 ${TOFU_PID} 2>/dev/null; do
    if [ -f "${PROJECT_ROOT}/.gsd/bootstrap-monitor-status" ]; then
      head -1 "${PROJECT_ROOT}/.gsd/bootstrap-monitor-status" 2>/dev/null | head -1 || true
    fi
    sleep 10
  done
  
  wait ${TOFU_PID}
  TOFU_EXIT=$?
  
  if [ ${TOFU_EXIT} -ne 0 ]; then
    echo "ERROR: tofu apply failed (exit ${TOFU_EXIT})" >&2
    exit 1
  fi
  
  # Export kubeconfig and talosconfig
  log_step "Exporting kubeconfig and talosconfig..."
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, subprocess, sys
try:
    out = subprocess.check_output(['tofu', 'output', '-json'], cwd='${TFDIR}', stderr=subprocess.DEVNULL)
    outputs = json.loads(out)
    tc = outputs.get('talosconfig', {}).get('value', {})
    if not tc:
        sys.exit(1)
    
    cidr = '${DEV_CIDR_BLOCK:-192.168.122.0/24}'
    net_base = '.'.join(cidr.split('.')[:3])
    cp_count = int('${DEV_CP_COUNT:-1}')
    worker_count = int('${DEV_WORKER_COUNT:-3}')
    
    cp_ips = [f'{net_base}.{100 + i}' for i in range(cp_count)]
    worker_ips = [f'{net_base}.{110 + i}' for i in range(worker_count)]
    all_ips = cp_ips + worker_ips
    
    config = f'''context: hpa-dev
contexts:
  hpa-dev:
    ca: {tc.get('ca_certificate', '')}
    crt: {tc.get('client_certificate', '')}
    endpoints:
{''.join(f'    - {ip}\\n' for ip in all_ips)}
    key: {tc.get('client_key', '')}
    nodes:
{''.join(f'    - {ip}\\n' for ip in all_ips)}
'''
    with open('${TFDIR}/talosconfig', 'w') as f:
        f.write(config)
    if outputs.get('kubeconfig', {}).get('value'):
        with open('${TFDIR}/kubeconfig', 'w') as f:
            f.write(outputs['kubeconfig']['value'])
except Exception as e:
    print(f'WARNING: Failed to generate talosconfig/kubeconfig: {e}', file=sys.stderr)
" 2>/dev/null || log_step "WARNING: Failed to generate talosconfig/kubeconfig"
  fi
  
  # Extract kubeconfig
  if [ -f "${TFDIR}/kubeconfig" ]; then
    local kubeconfig_dest="${KUBECONFIG:-${PROJECT_ROOT}/kubeconfig}"
    cp "${TFDIR}/kubeconfig" "${kubeconfig_dest}"

    log_step "Kubeconfig saved to ${kubeconfig_dest}"
  fi
  
  echo ">>> OpenTofu apply complete" >&3
}

main "$@"

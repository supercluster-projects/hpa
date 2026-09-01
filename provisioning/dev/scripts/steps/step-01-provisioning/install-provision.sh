#!/usr/bin/env bash
# Install OpenTofu provisioning + bootstrap Talos cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../misc/preamble.sh"

ensure_talosctl_version() {
  local expected="${TALOS_VERSION:-1.13.5}"
  local bin
  local installed
  local tmp_bin
  local tmp_dir

  tmp_dir="$(mktemp -d)"
  tmp_bin="${tmp_dir}/talosctl"
  bin="$(command -v talosctl || true)"
  if [ -z "${bin}" ]; then
    echo "WARNING: talosctl not found; installing Talos ${expected} talosctl" >&2
  else
    installed="$(talosctl version --client 2>/dev/null | awk -F': ' '/Tag/{gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    if [ -z "${installed}" ] || [ "${installed}" != "${expected}" ]; then
      echo "WARNING: talosctl ${installed:-unknown} does not match Talos ${expected}; installing matching talosctl ${expected}" >&2
    else
      rm -rf "${tmp_dir}"
      return 0
    fi
  fi

  if ! curl -L "https://github.com/siderolabs/talos/releases/download/v${expected}/talosctl-linux-amd64" -o "${tmp_bin}" 2>"${tmp_dir}/install.err"; then
    echo "ERROR: failed to install talosctl: $(cat "${tmp_dir}/install.err")" >&2
    rm -rf "${tmp_dir}"
    return 1
  fi
  chmod +x "${tmp_bin}"
  mv "${tmp_bin}" "${HOME}/.local/bin/talosctl"
  chmod +x "${HOME}/.local/bin/talosctl"
  export PATH="${HOME}/.local/bin:${PATH}"
  rm -rf "${tmp_dir}"
}

ensure_bootstrap_images() {
  local k8s_version="${K8S_VERSION:-1.36.0}"
  local etcd_version="${TALOS_ETCD_VERSION:-3.6.12}"
  local cidr="${DEV_CIDR_BLOCK:-192.168.122.0/24}"
  local net_base
  local cp_count
  local worker_count
  local cp_ip
  local ip
  local nodes=()

  net_base="$(
    python3 - "${cidr}" <<'PY'
import ipaddress, sys

ip = ipaddress.ip_network(sys.argv[1], strict=False).network_address
parts = str(ip).split('.')
print('.'.join(parts[:3]) if len(parts) == 4 else ip)
PY
  )"
  cp_count="${DEV_CP_COUNT:-1}"
  worker_count="${DEV_WORKER_COUNT:-3}"
  cp_ip="${net_base}.100"

  nodes+=("${cp_ip}")
  for ((i = 0; i < worker_count; i++)); do
    nodes+=("${net_base}.$((110 + i))")
  done

  log_step "Pre-pulling bootstrap images on Talos nodes (${k8s_version})..."
  for ip in "${nodes[@]}"; do
    if [ "${ip}" = "${cp_ip}" ]; then
      log_step "Pulling etcd:v${etcd_version} on ${ip}"
      talosctl image pull --nodes "${ip}" --namespace system "registry.k8s.io/etcd:v${etcd_version}"
    fi
    log_step "Pulling kubelet:v${k8s_version} on ${ip}"
    talosctl image pull --nodes "${ip}" --namespace system "ghcr.io/siderolabs/kubelet:v${k8s_version}"
  done
}

main() {
  echo ">>> Step 01: Running OpenTofu apply..." >&3
  PRE_PULL_BOOTSTRAP_IMAGES="${PRE_PULL_BOOTSTRAP_IMAGES:-false}"  # Disabled by default: Talos API can lag behind libvirt boot, and the offline registry already seeds bootstrap images.

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

  ensure_talosctl_version

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

  if [ "${OFFLINE_MODE:-false}" = "true" ]; then
    log_step "OFFLINE_MODE=true: preparing local bootstrap registry at ${REGISTRY_URL:-http://${GATEWAY_IP}:5000}"
    bash "${MISC_DIR}/setup-local-registry.sh" || die "Offline bootstrap registry preparation failed"
  else
    log_step "OFFLINE_MODE=false: using public registries for bootstrap images"
  fi

  # Generate variables file for OpenTofu
  TMP_VARS="${TFDIR}/dev.auto.tfvars"
  log_step "Generating ${TMP_VARS}..."
  {
    for var_name in DEV_CLUSTER_NAME DEV_CP_COUNT DEV_WORKER_COUNT DEV_VM_CPU \
                    DEV_CP_RAM_MB DEV_WORKER_RAM_MB DEV_OS_DISK_SIZE_GB \
                    DEV_CEPH_DISK_SIZE_GB DEV_BRIDGE_NAME DEV_NODE_PREFIX \
                    DEV_CIDR_BLOCK TALOS_VERSION OFFLINE_MODE; do
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

  # Run OpenTofu apply. Keep the verbose plan/apply table out of startup.log and keep
  # the full OpenTofu transcript in its own log file for diagnostics.
  log_step "Running tofu apply -auto-approve..."
  TOFU_LOG="${PROJECT_ROOT}/.tofu-apply.log"
  : > "${TOFU_LOG}"
  (cd "${TFDIR}" && tofu apply -auto-approve) >"${TOFU_LOG}" 2>&1 &
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
  log_step "OpenTofu apply completed"

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
    kubeconfig_dest="${KUBECONFIG:-${PROJECT_ROOT}/kubeconfig}"
    if [ "${kubeconfig_dest}" != "${TFDIR}/kubeconfig" ]; then
      mkdir -p "$(dirname "${kubeconfig_dest}")"
      cp "${TFDIR}/kubeconfig" "${kubeconfig_dest}"
    fi

    log_step "Kubeconfig saved to ${kubeconfig_dest}"
  fi

  if [ -f "${TFDIR}/talosconfig" ]; then
    if [ "${PRE_PULL_BOOTSTRAP_IMAGES}" = "true" ]; then
      ensure_bootstrap_images || log_step "WARNING: Bootstrap image pre-pull failed; continuing to bootstrap"
    else
      log_step "Bootstrap image pre-pull skipped (set PRE_PULL_BOOTSTRAP_IMAGES=true to enable it)"
    fi
  else
    log_step "WARNING: talosconfig not found; skipping bootstrap image pre-pull"
  fi

  echo ">>> OpenTofu apply complete" >&3
}

main "$@"

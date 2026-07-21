#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# startup.sh — Full dev environment bootstrap in one shot
#
# Orchestrates the complete pipeline from bare metal to a running HPA dev
# cluster. Handles everything: VM provisioning via OpenTofu, then all Helm
# charts and workload deployments. Every step is idempotent.
#
# Usage: ./startup.sh [options]
#
# Options:
#   --kubeconfig PATH   Path to kubeconfig (default: ../opentofu/kubeconfig)
#   --tofu-dir DIR      OpenTofu provisioning directory (default: ../opentofu)
#   --envoy-ip IP       Envoy LB IP for endpoint verification (auto-detected
#                       if omitted, must be within DEV_LB_POOL_CIDR)
#   --skip-tofu         Skip OpenTofu provisioning (use existing kubeconfig)
#   --help, -h          Show this help message
#
# Environment:
#   .env file at project root sourced automatically if present
#   CLI flags override env vars which override script defaults
#
#   INFISICAL_ENCRYPTION_KEY   Must be set in .env (no default)
#   INFISICAL_ADMIN_PASSWORD   Must be set in .env (no default)
#   INFISICAL_AUTH_SECRET      Must be set in .env (no default)
#
# Exit code: 0 on success, non-zero on first failure
#
# All stdout/stderr is also captured to startup.log at project root.
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/misc/preamble.sh"

# ---- Log setup: capture all output to startup.log at project root --------
# Save fd 3 to the raw terminal BEFORE the tee redirect, so that the
# bootstrap monitor and progress table can write updating lines that
# overwrite each other on screen without accumulating in startup.log.
exec 3>&2

STARTUP_LOG="${PROJECT_ROOT}/startup.log"
# Clear the log file at the start of each run so stale output is not confusing.
: > "${STARTUP_LOG}"
exec > >(tee -a "${STARTUP_LOG}") 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Logging all output to ${STARTUP_LOG}"

# ---- Bootstrap .env if missing --------------------------------------------
ENV_SAMPLE="${PROJECT_ROOT}/.env.example"
if [ ! -f "${PROJECT_ROOT}/.env" ] && [ -f "${ENV_SAMPLE}" ]; then
  cp "${ENV_SAMPLE}" "${PROJECT_ROOT}/.env"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Created .env from .env.example — review and edit if needed."
  # Source the newly created .env
  set -a; source "${PROJECT_ROOT}/.env"; set +a
fi

# ---- Config ---------------------------------------------------------------
ENVOY_IP=""
TOFU_DIR="${SCRIPT_DIR}/../opentofu"
SKIP_TOFU=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)  KUBECONFIG="$2";  shift 2 ;;
    --envoy-ip)    ENVOY_IP="$2";    shift 2 ;;
    --tofu-dir)    TOFU_DIR="$2";    shift 2 ;;
    --skip-tofu)   SKIP_TOFU=true;    shift ;;
    --help|-h)
      cat <<HELP
Usage: $(basename "$0") [options]

Full dev environment bootstrap in one shot — from bare metal to a running
HPA dev cluster. Provisions VMs via OpenTofu, then installs all platform
components and workloads.

Options:
  --skip-tofu         Skip VM provisioning (use existing kubeconfig)
  --tofu-dir DIR      OpenTofu directory (default: ../opentofu)
  --kubeconfig PATH   Path to kubeconfig (default: ../opentofu/kubeconfig)
  --envoy-ip IP       Envoy LB IP for endpoint verification
  --help, -h          Show this help message

Pipeline steps:
  0. Setup hpa-bridge network (configure bridge & tap device)
  1. OpenTofu apply (Provision Talos VMs + kubeconfig)     [skip with --skip-tofu]
  2. Install Cilium CNI
  3. Install Rook Ceph
  4. Install Harbor
  5. Install Infisical
  6. Install Runtimes (cert-manager, Knative, SpinKube, KeyDB)
  7. Install Kafka (Strimzi Operator + Cluster)
  8. Install Spegel P2P OCI Registry Mirror
  9. Install Casdoor OIDC Provider
  10. Install Casbin gRPC Authorizer
  11. Install Envoy Gateway + Headlamp
  12. Install SecurityPolicy (Casbin extAuth + Casdoor OIDC)
  13. Install GitOps (Kargo + ArgoCD)
  14. Deploy Workloads (Welcome + Counter)
  15. Install Streaming Workload (Stream-Processor)
  16. Bootstrap Infisical Workloads
  17. Install Yugabytedb Distributed SQL
  18. Install Hasura GraphQL Engine
  19. Install VMSingle (VictoriaMetrics TSDB)
  20. Install vmagent DaemonSet (metric scraper)
  21. Install kube-state-metrics
  22. Install Grafana Dashboards
  23. Install AlertManager
  24. Configure TLS + Routes
  25. Seed hydration (offline images to Harbor) [SKIP if SEED_DIR unset] (cert-manager, HTTPS, gql, welcome)

Environment:
  .env file at project root sourced automatically

Exit 0 on success, non-zero on first failure.
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# Export KUBECONFIG for subprocesses
export KUBECONFIG

# ---- Setup bridge network (always runs first, before cleanup) -------------
STEP_START "Setup hpa-bridge network"
bash "${SCRIPT_DIR}/steps/step-01-bridge-setup/setup-bridge.sh" && STEP_END "DONE" || {
  STEP_END "FAILED" "Bridge setup failed"
  die "setup-bridge.sh failed"
}

# ---- OpenTofu provisioning (skip with --skip-tofu) -----------------------
# Check if cluster is already healthy and accessible via existing kubeconfig
CLUSTER_HEALTHY=false
if [ -f "${KUBECONFIG}" ]; then
  if command -v kubectl >/dev/null 2>&1; then
    if kubectl --kubeconfig "${KUBECONFIG}" get nodes 2>/dev/null | grep -q "Ready"; then
      CLUSTER_HEALTHY=true
    fi
  fi
fi

# Run tofu apply if: not skipped, and either cluster is unhealthy or kubeconfig doesn't exist
if [ "${SKIP_TOFU}" = false ] && [ "${CLUSTER_HEALTHY}" = false ]; then
  STEP_START "Provision Talos VMs (OpenTofu)"
  log "tofu dir:     ${TOFU_DIR}"
  log "kubeconfig:   ${KUBECONFIG}"

  command -v tofu >/dev/null 2>&1 || die "OpenTofu (tofu) not found in PATH"

  TOFU_ABS_DIR="$(cd "${TOFU_DIR}" 2>/dev/null && pwd)"
  if [ -z "${TOFU_ABS_DIR}" ]; then
    die "OpenTofu directory not found at ${TOFU_DIR}"
  fi

  # tofu init
  log "Running tofu init..."
  (cd "${TOFU_ABS_DIR}" && tofu init -backend=false) 2>&1 | grep -E "✓|Successfully|Error|warning" || true

  # Verify libvirtd
  if ! virsh -c qemu:///system list >/dev/null 2>&1; then
    die "libvirtd is not reachable via 'virsh list'. Ensure libvirtd is running and the current user is in the libvirt group."
  fi

  # Pre-flight cleanup (only runs when tofu apply is about to execute)
  log "Running pre-flight cleanup..."
  bash "${MISC_DIR}/cleanup-preflight.sh" --prefix "${DEV_NODE_PREFIX}" --tofu-dir "${TOFU_ABS_DIR}" 2>&1 || {
    log "Pre-flight cleanup had minor issues — continuing anyway."
  }

  log "Running tofu apply -auto-approve..."

  TFDIR="${TOFU_ABS_DIR}"
  TMP_VARS="${TFDIR}/dev.auto.tfvars"

  # Generate .auto.tfvars from env vars (sourced from .env by preamble.sh).
  # Only writes variables that are actually set — tofu will fail for any
  # missing required variable, which is the desired behavior.
  log "Generating ${TMP_VARS} from .env variables..."
  {
    for var_name in DEV_CLUSTER_NAME DEV_CP_COUNT DEV_WORKER_COUNT DEV_VM_CPU \
                    DEV_CP_RAM_MB DEV_WORKER_RAM_MB DEV_OS_DISK_SIZE_GB \
                    DEV_CEPH_DISK_SIZE_GB DEV_BRIDGE_NAME DEV_NODE_PREFIX \
                    DEV_CIDR_BLOCK TALOS_VERSION DEV_TALOS_IMAGE_FACTORY_URL; do
      if [ -n "${!var_name:-}" ]; then
        # Quote strings, keep numbers bare
        case "$var_name" in
          DEV_CP_COUNT|DEV_WORKER_COUNT|DEV_VM_CPU|DEV_CP_RAM_MB|DEV_WORKER_RAM_MB|DEV_OS_DISK_SIZE_GB|DEV_CEPH_DISK_SIZE_GB)
            echo "${var_name} = ${!var_name}"
            ;;
          *)
            echo "${var_name} = \"${!var_name}\""
            ;;
        esac
      fi
    done
  } > "${TMP_VARS}"

  log "Generated ${TMP_VARS}."
  log "Contents:"
  while IFS= read -r line; do log "  ${line}"; done < "${TMP_VARS}"

  # ---- Pre-create host-backed persistent Ceph disk sparse files -----------
  CEPH_DIR="/var/lib/libvirt/images/ceph-disks"
  if [ ! -d "${CEPH_DIR}" ]; then
    log "Creating Ceph persistent disks directory ${CEPH_DIR}..."
    sudo mkdir -p "${CEPH_DIR}"
    sudo chmod 755 "${CEPH_DIR}"
  fi

  for worker in ${DEV_NODE_PREFIX}-worker-0 ${DEV_NODE_PREFIX}-worker-1 ${DEV_NODE_PREFIX}-worker-2; do
    DISK_PATH="${CEPH_DIR}/${worker}-ceph.img"
    if [ ! -f "${DISK_PATH}" ]; then
      log "Creating persistent sparse Ceph disk for ${worker} (${DEV_CEPH_DISK_SIZE_GB} GiB)..."
      sudo truncate -s "${DEV_CEPH_DISK_SIZE_GB}G" "${DISK_PATH}"
      sudo chmod 666 "${DISK_PATH}"
    fi
  done

  # Compute CP0 IP from the CIDR block (same formula as locals.tf: base + 100)
  # Must be derived before tofu apply since outputs don't exist yet.
  CP0_IP="$(echo "${DEV_CIDR_BLOCK}" | awk -F'[./]' '{printf "%s.%s.%s.100", $1, $2, $3}')"
  OS_DISK_PATH="/var/lib/libvirt/images/${DEV_NODE_PREFIX}-cp-0-os.qcow2"
  KUBECONFIG_PATH="${KUBECONFIG}"

  # Setup local registry and seed bootstrap images for offline mode
  if [ "${OFFLINE_MODE:-false}" = "true" ]; then
    STEP_START "Setup Local Registry & Seed Bootstrap Images"
    log "Ensuring local OCI registry is running on the host..."
    bash "${SCRIPT_DIR}/setup-local-registry.sh" || die "setup-local-registry.sh failed"
    log "Seeding bootstrap images to local registry..."
    bash "${SCRIPT_DIR}/bootstrap-harbor.sh" --host || die "bootstrap-harbor.sh failed"
    STEP_END "DONE"
  fi

  # Setup local dev overlay registry
  STEP_START "Setup Local Dev Overlay Registry"
  if [ -n "${DEV_LOCAL_REGISTRY:-}" ]; then
    log "Using DEV_LOCAL_REGISTRY overlay: ${DEV_LOCAL_REGISTRY}"
    bash "${DEV_LOCAL_REGISTRY}" || die "DEV_LOCAL_REGISTRY overlay setup failed"
    STEP_END "DONE"
  else
    STEP_END "SKIPPED (DEV_LOCAL_REGISTRY not set)"
  fi

  # Start real-time bootstrap monitor in background.
  bash "${SCRIPT_DIR}/monitor-bootstrap.sh" \
    "${CP0_IP}" "${OS_DISK_PATH}" "${KUBECONFIG_PATH}" &
  MONITOR_PID=$!

  # Run tofu apply in background.
  # Capture output quietly, show periodic progress
  TOFU_LOG="${PROJECT_ROOT}/.tofu-apply.log"
  (cd "${TFDIR}" && tofu apply -auto-approve 2>&1 | tee "${TOFU_LOG}") &
  TOFU_PID=$!

  # Poll for tofu completion and show bootstrap monitor status
  while kill -0 ${TOFU_PID} 2>/dev/null; do
    # Show latest status from monitor
    if [ -f "${MONITOR_STATUS_FILE:-${PROJECT_ROOT}/.gsd/bootstrap-monitor-status}" ]; then
      STATUS=$(head -1 "${MONITOR_STATUS_FILE:-${PROJECT_ROOT}/.gsd/bootstrap-monitor-status}" 2>/dev/null || echo "")
      [ -n "${STATUS}" ] && log "Bootstrap progress: ${STATUS}"
    fi
    # Show tofu completion line if found
    if [ -f "${TOFU_LOG}" ]; then
      LAST=$(grep -E "Apply complete|destroyed|created|created in" "${TOFU_LOG}" 2>/dev/null | tail -1 || true)
      [ -n "${LAST}" ] && log "Tofu: ${LAST}"
    fi
    sleep 5
  done
  set +e; wait ${TOFU_PID}; TOFU_EXIT=$?; set -e

  if [ "${TOFU_EXIT}" -ne 0 ]; then
    log "FAILED: Contents of ${TMP_VARS}:"
    if [ -f "${TMP_VARS}" ]; then
      while IFS= read -r line; do log "  ${line}"; done < "${TMP_VARS}"
    else
      log "  (file was not created — no env vars were set)"
    fi
    kill "${MONITOR_PID}" 2>/dev/null || true
    rm -f "${TMP_VARS}"
    die "tofu apply failed"
  fi

  # Kill the bootstrap monitor (tofu apply done)
  kill "${MONITOR_PID}" 2>/dev/null || true

  # Write kubeconfig to disk from tofu state output
  mkdir -p "$(dirname "${KUBECONFIG}")"
  (cd "${TFDIR}" && tofu output -raw kubeconfig 2>/dev/null) > "${KUBECONFIG}" || {
    log "WARNING: Failed to extract kubeconfig from tofu state"
    log "  The cluster may not be fully bootstrapped yet."
  }

  # Generate talosconfig programmatically from tofu state output
  python3 -c "
import json, subprocess
try:
    out = subprocess.check_output(['tofu', 'output', '-json'], cwd='${TFDIR}')
    outputs = json.loads(out)
    tc = outputs['talosconfig']['value']
    # Derive IPs from CIDR base — same formula as locals.tf
    cidr = '${DEV_CIDR_BLOCK}'
    net_base = '.'.join(cidr.split('.')[:3])
    cp_ips = [f'{net_base}.{100 + i}' for i in range(${DEV_CP_COUNT})]
    worker_ips = [f'{net_base}.{110 + i}' for i in range(${DEV_WORKER_COUNT})]
    all_ips = cp_ips + worker_ips
    all_nodes = all_ips  # nodes list = same IPs as endpoints
    endpoints_yaml = '\\n'.join(f'    - {ip}' for ip in all_ips)
    nodes_yaml = '\\n'.join(f'    - {ip}' for ip in all_ips)
    config = f'''context: hpa-dev
contexts:
  hpa-dev:
    ca: {tc['ca_certificate']}
    crt: {tc['client_certificate']}
    endpoints:
{endpoints_yaml}
    key: {tc['client_key']}
    nodes:
{nodes_yaml}
'''
    with open('${TFDIR}/talosconfig', 'w') as f:
        f.write(config)
except Exception as e:
    print('WARNING: Failed to generate talosconfig:', e)
" 2>/dev/null || true

  log "tofu apply completed successfully."
  STEP_END "DONE"
elif [ "${CLUSTER_HEALTHY}" = true ]; then
  log "Cluster is healthy - using existing kubeconfig"
elif [ "${SKIP_TOFU}" = true ]; then
  log "--skip-tofu set — using existing kubeconfig (if any)."
else
  # kubeconfig exists but cluster is unhealthy
  log "WARNING: kubeconfig exists but cluster is unhealthy - needs re-bootstrap"
fi

# ---- Verify cluster access ------------------------------------------------
log "Verifying cluster connectivity..."

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v helm >/dev/null 2>&1   || die "helm not found"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

log "Waiting for cluster nodes to become reachable..."
WAIT_OK=false
for i in {1..120}; do
  if kubectl get nodes >/dev/null 2>&1; then
    WAIT_OK=true
    break
  fi
  log "  Kubernetes API not ready yet, retrying in 5s... ($i/120)"
  sleep 5
done

if [ "${WAIT_OK}" = false ]; then
  die "Cannot reach cluster via kubeconfig at ${KUBECONFIG}"
fi

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
log "Cluster reachable (${NODE_COUNT} nodes)."

# ---- Run pipeline ---------------------------------------------------------
cd "${SCRIPT_DIR}"

require_env INFISICAL_ENCRYPTION_KEY 2>/dev/null || {
  log "INFISICAL_ENCRYPTION_KEY not set in .env — install-infisical.sh will fail."
}
require_env INFISICAL_ADMIN_PASSWORD 2>/dev/null || {
  log "INFISICAL_ADMIN_PASSWORD not set in .env — install-infisical.sh will fail."
}
require_env INFISICAL_AUTH_SECRET 2>/dev/null || {
  log "INFISICAL_AUTH_SECRET not set in .env — install-infisical.sh will fail."
}

step() {
  local num=$1
  local name=$2
  local script=$3
  local verify_script=${4:-""}
  shift 3
  if [ -n "${verify_script}" ]; then
    shift
  fi

  STEP_START "Step ${num}: ${name}"

  # Redirect script output to the tee pipe (fd 1/2) so it goes to startup.log
  if bash "${script}" "$@" 2>&1; then
    if [ -n "${verify_script}" ]; then
      log ">>> Running live verification for Step ${num}: ${verify_script}..."
      if bash "${verify_script}" 2>&1; then
        STEP_END "DONE"
        log ">>> Completed Step ${num}: ${name} — SUCCESS"
      else
        local code=$?
        STEP_END "FAILED" "verification failed (exit ${code})"
        die "Step ${num}: ${name} — VERIFICATION FAILED (exit code ${code})"
      fi
    else
      STEP_END "DONE"
      log ">>> Completed Step ${num}: ${name} — SUCCESS"
    fi
  else
    local code=$?
    STEP_END "FAILED" "installation failed (exit ${code})"
    die "Step ${num}: ${name} — INSTALLATION FAILED (exit code ${code})"
  fi
}

TOTAL_STEPS=26

# Define steps directory
STEPS_DIR="${SCRIPT_DIR}/steps"
MISC_DIR="${SCRIPT_DIR}/misc"

# Step 0 (setup-bridge) was already done inline before tofu — idempotent, skip here.
step 2 "Install Cilium CNI"         "${STEPS_DIR}/step-02-cilium/install-cilium.sh" "${STEPS_DIR}/step-02-cilium/verify-cilium.sh"
step 3 "Install Rook Ceph"          "${STEPS_DIR}/step-03-rook-ceph/install-rook-ceph.sh" "${STEPS_DIR}/step-03-rook-ceph/verify-ceph.sh"
step 4 "Install Harbor"             "${STEPS_DIR}/step-04-harbor/install-harbor.sh" "${STEPS_DIR}/step-04-harbor/verify-harbor.sh"
step 5 "Install Infisical"          "${STEPS_DIR}/step-05-infisical/install-infisical.sh" "${STEPS_DIR}/step-05-infisical/verify-infisical.sh"
step 6 "Install Runtimes (cert-manager, Knative, SpinKube, KeyDB)" \
                                     "${STEPS_DIR}/step-06-runtimes/install-runtimes.sh" "${STEPS_DIR}/step-06-runtimes/verify-runtimes.sh"
step 7 "Install Kafka (Strimzi Operator + Cluster)" \
                                     "${STEPS_DIR}/step-07-kafka/install-kafka.sh" "${STEPS_DIR}/step-07-kafka/verify-kafka.sh"
step 8 "Install Spegel P2P OCI Registry Mirror" \
                                     "${STEPS_DIR}/step-08-spegel/install-spegel.sh" "${STEPS_DIR}/step-08-spegel/verify-spegel.sh"
step 9 "Install Casdoor OIDC Provider" \
                                     "${STEPS_DIR}/step-09-casdoor/install-casdoor.sh" "${STEPS_DIR}/step-09-casdoor/verify-casdoor.sh"
step 10 "Install Casbin gRPC Authorizer" \
                                     "${STEPS_DIR}/step-10-casbin/install-casbin.sh" "${STEPS_DIR}/step-10-casbin/verify-casbin.sh"
step 11 "Install Envoy Gateway + Headlamp" \
                                     "${STEPS_DIR}/step-11-gateway/install-gateway.sh" "${STEPS_DIR}/step-11-gateway/verify-gateway.sh"
step 12 "Apply SecurityPolicy (Casbin extAuth + Casdoor OIDC)" \
                                     "${STEPS_DIR}/step-12-security-policy/install-security-policy.sh" "${STEPS_DIR}/step-12-security-policy/verify-security-policy.sh"
step 13 "Install GitOps (Kargo + ArgoCD)" \
                                     "${STEPS_DIR}/step-13-gitops/install-gitops.sh" "${STEPS_DIR}/step-13-gitops/verify-gitops.sh"
step 14 "Deploy Workloads (Welcome + Counter)" \
                                     "${STEPS_DIR}/step-14-workloads/install-workloads.sh" "${STEPS_DIR}/step-14-workloads/verify-workloads.sh"
step 15 "Install Streaming Workload (Stream-Processor)" \
                                     "${STEPS_DIR}/step-15-streaming-workload/install-streaming-workload.sh" "${STEPS_DIR}/step-15-streaming-workload/verify-streaming-workload.sh"
step 16 "Bootstrap Infisical Workloads"  "${STEPS_DIR}/step-16-infisical-workloads/bootstrap-infisical-workloads.sh" "${STEPS_DIR}/step-16-infisical-workloads/verify-infisical-workloads.sh"
step 17 "Install Yugabytedb Distributed SQL"  "${STEPS_DIR}/step-17-yugabytedb/install-yugabytedb.sh" "${STEPS_DIR}/step-17-yugabytedb/verify-yugabytedb.sh"
step 18 "Install Hasura GraphQL Engine"  "${STEPS_DIR}/step-18-hasura/install-hasura.sh" "${STEPS_DIR}/step-18-hasura/verify-hasura.sh"
step 19 "Install VMSingle (VictoriaMetrics TSDB)"  "${STEPS_DIR}/step-19-vm-single/install-vm-single.sh" "${STEPS_DIR}/step-19-vm-single/verify-vm.sh"
step 20 "Install vmagent DaemonSet"  "${STEPS_DIR}/step-20-vmagent/install-vmagent.sh"
step 21 "Install kube-state-metrics"  "${STEPS_DIR}/step-21-kube-state-metrics/install-kube-state-metrics.sh"
step 22 "Install Grafana Dashboards"  "${STEPS_DIR}/step-22-grafana/install-grafana.sh" "${STEPS_DIR}/step-22-grafana/verify-grafana.sh"
step 23 "Install AlertManager"  "${STEPS_DIR}/step-23-alertmanager/install-alertmanager.sh" "${STEPS_DIR}/step-23-alertmanager/verify-observability.sh"
step 24 "Configure TLS + Routes"  "${STEPS_DIR}/step-24-tls/install-tls.sh" "${STEPS_DIR}/step-24-tls/verify-tls.sh"
step 26 "Install CouchDB Document Store" "${STEPS_DIR}/step-26-couchdb/install-couchdb.sh" "${STEPS_DIR}/step-26-couchdb/verify-couchdb.sh"

# Step 25: Seed hydration — only runs if SEED_DIR is set (air-gapped mode)
if [ -n "${SEED_DIR:-}" ]; then
  log "Step 25: Hydrating Harbor from seed..."
  "${STEPS_DIR}/step-25-seed-hydration/hydrate-harbor.sh" 2>&1 || log "  (non-fatal) Harbor hydration had issues"
  "${STEPS_DIR}/step-25-seed-hydration/hydrate-tofu.sh" 2>&1 || log "  (non-fatal) Tofu hydration had issues"
else
  log "Step 25: SEED_DIR not set — skipping seed hydration"
fi

# ---- Run verification scripts ---------------------------------------------
log ""
log "========== Running Verification Scripts =========="

# Check static artifacts first
log "--- verify-manifests.sh (static) ---"
bash "${MISC_DIR}/verify-manifests.sh" 2>&1 || log "  (non-fatal) Some repos may be unreachable"

# If SEED_DIR is set, verify seed artifacts
if [ -n "${SEED_DIR:-}" ]; then
  log "--- verify-seed.sh ---"
  bash "${MISC_DIR}/verify-seed.sh" --seed-dir "${SEED_DIR}" 2>&1 || log "  (non-fatal) Seed verification had issues"
fi
# Runtime checks
for verify_script in "${STEPS_DIR}/step-02-cilium/verify-cilium.sh" "${STEPS_DIR}/step-03-rook-ceph/verify-ceph.sh" "${STEPS_DIR}/step-04-harbor/verify-harbor.sh" \
                     "${STEPS_DIR}/step-05-infisical/verify-infisical.sh" "${STEPS_DIR}/step-06-runtimes/verify-runtimes.sh" "${STEPS_DIR}/step-07-kafka/verify-kafka.sh" "${STEPS_DIR}/step-08-spegel/verify-spegel.sh" \
                     "${STEPS_DIR}/step-09-casdoor/verify-casdoor.sh" "${STEPS_DIR}/step-10-casbin/verify-casbin.sh" "${STEPS_DIR}/step-11-gateway/verify-gateway.sh" "${STEPS_DIR}/step-12-security-policy/verify-security-policy.sh" "${STEPS_DIR}/step-13-gitops/verify-gitops.sh"; do
  log "--- $(basename ${verify_script}) ---"
  bash "${verify_script}" 2>&1 || log "  (non-fatal) Some checks may need more time"
done

# Additional runtime checks (from the original for loop)
for verify_script in "${STEPS_DIR}/step-04-harbor/verify-harbor.sh" \
                     "${STEPS_DIR}/step-05-infisical/verify-infisical.sh" "${STEPS_DIR}/step-16-infisical-workloads/verify-infisical-workloads.sh" "${STEPS_DIR}/step-17-yugabytedb/verify-yugabytedb.sh" "${STEPS_DIR}/step-26-couchdb/verify-couchdb.sh" "${STEPS_DIR}/step-18-hasura/verify-hasura.sh" "${MISC_DIR}/verify-datagraph.sh" "${STEPS_DIR}/step-19-vm-single/verify-vm.sh" "${STEPS_DIR}/step-22-grafana/verify-grafana.sh" "${STEPS_DIR}/step-23-alertmanager/verify-observability.sh" "${STEPS_DIR}/step-24-tls/verify-tls.sh" "${MISC_DIR}/verify-mesh.sh" "${STEPS_DIR}/step-06-runtimes/verify-runtimes.sh" "${STEPS_DIR}/step-07-kafka/verify-kafka.sh" "${STEPS_DIR}/step-08-spegel/verify-spegel.sh" \
                     "${STEPS_DIR}/step-09-casdoor/verify-casdoor.sh" "${STEPS_DIR}/step-10-casbin/verify-casbin.sh" "${STEPS_DIR}/step-11-gateway/verify-gateway.sh" "${STEPS_DIR}/step-12-security-policy/verify-security-policy.sh" "${STEPS_DIR}/step-13-gitops/verify-gitops.sh"; do
  log "--- $(basename ${verify_script}) ---"
  bash "${verify_script}" 2>&1 || log "  (non-fatal) Some checks may need more time"
done

# ---- Summary --------------------------------------------------------------
DURATION=$(( $(date +%s) - START_TIME ))
MINUTES=$(( DURATION / 60 ))
SECONDS=$(( DURATION % 60 ))

log ""
log "=========================================================="
log "Bootstrap Complete!"
log "  Duration: ${MINUTES}m ${SECONDS}s"
log "  kubeconfig: ${KUBECONFIG}"
log ""
log "  Envoy Gateway:"
log "    kubectl -n envoy-gateway-system get gateway hpa-dev-gateway"
log ""
log "  Quick verification:"
log "    curl http://<envoy-ip>/api/welcome"
log ""
log "  Headlamp:"
log "    http://<envoy-ip>/admin"
log ""
log "  Cleanup:"
log "    ./cleanup.sh"
log "=========================================================="

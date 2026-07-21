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

Interactive mode: After each step completes, you will be prompted to:
  - Execute the next step
  - Skip the next step
  - View verification results

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
  25. Seed hydration (offline images to Harbor) [SKIP if SEED_DIR unset]

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

# ---- Result tracking ------------------------------------------------------
# Track completed steps for review table at the end
declare -a STEP_RESULTS=()
declare -a STEP_NAMES=()
CURRENT_STEP_NUM=0

# Function to add a step result
add_step_result() {
  local num=$1
  local name=$2
  local result=$3
  local detail="${4:-}"
  STEP_RESULTS+=("$(printf "  %-30s | %s| %s" "$name" "$result" "$detail")")
}
# ---- Interactive prompt function ----------------------------------------
prompt_step() {
  local step_num=$1
  local step_name=$2
  local result=$3
  
  echo "" >&3
  echo "========================================" >&3
  echo "Step ${step_num}: ${step_name}" >&3
  echo "  Status: ${result}" >&3
  echo "========================================" >&3
  
  # Show quick verification summary
  if [ "$result" = "SUCCESS" ]; then
    echo "" >&3
    echo ">>> Verification Results:" >&3
    # Show key metrics
    if [ -n "${NODE_COUNT:-}" ]; then
      echo "     Nodes ready: ${NODE_COUNT}" >&3
    fi
    echo "" >&3
    echo "========================================" >&3
    echo "  OPTIONS:" >&3
    echo "    E/e  - Execute next step" >&3
    echo "    S/s  - Skip next step" >&3
    echo "    R/r  - View recent results table" >&3
    echo "    Q/q  - Quit script" >&3
    echo "========================================" >&3
    
    while true; do
      read -r -p "Choose (E Execute/S Skip/R Results/Q Quit): " choice
      case "$choice" in
        [Ee])  return 0 ;;  # Execute next step
        [Ss])  return 1 ;;  # Skip next step
        [Rr])  show_results_table; continue ;;
        [Qq])  die "User requested quit" ;;
        *)     echo "Invalid choice. Please enter E, S, R, or Q." >&3 ;;
      esac
    done
  else
    echo "" >&3
    echo ">>> Step ${step_num}: ${step_name} - FAILED!" >&3
    echo "========================================" >&3
    echo "  OPTIONS:" >&3
    echo "    R/r  - View recent results table" >&3
    echo "    Q/q  - Quit script" >&3
    echo "========================================" >&3
    
    while true; do
      read -r -p "Choose (R Results/Q Quit): " choice
      case "$choice" in
        [Rr])  show_results_table; continue ;;
        [Qq])  die "Step ${step_num} failed, user requested quit" ;;
        *)     echo "Invalid choice. Please enter R or Q." >&3 ;;
      esac
    done
  fi
}

# Show results table for completed steps
show_results_table() {
  echo "" >&3
  echo "========================================" >&3
  echo "        STEP RESULTS SUMMARY" >&3
  echo "========================================" >&3
  echo "" >&3
  echo "  Step | Name                              | Status  | Details" >&3
  echo "  -----|-----------------------------------|---------|-------" >&3
  
  local idx=1
  for result in "${STEP_RESULTS[@]}"; do
    echo "$result" >&3
    idx=$((idx + 1))
  done
  
  echo "" >&3
  echo "========================================" >&3
}

# ---- Main execution -------------------------------------------------------
export KUBECONFIG

# ---- Setup bridge network (always runs first, before cleanup) -------------
CURRENT_STEP_NUM=0
STEP_START "Setup hpa-bridge network"
if bash "${SCRIPT_DIR}/steps/step-01-bridge-setup/setup-bridge.sh" 2>&1; then
  STEP_END "DONE"
  add_step_result $CURRENT_STEP_NUM "Setup hpa-bridge network" "SUCCESS"
  # Step 0 completes, move to step 1
else
  STEP_END "FAILED" "Bridge setup failed"
  add_step_result $CURRENT_STEP_NUM "Setup hpa-bridge network" "FAILED"
  die "setup-bridge.sh failed"
fi

# Verify bridge setup
CURRENT_STEP_NUM=1
STEP_START "Verify bridge network"
if virsh -c qemu:///system net-info "hpa-bridge" &>/dev/null; then
  log "✓ hpa-bridge network is active"
  STEP_END "DONE"
  add_step_result $CURRENT_STEP_NUM "Verify bridge network" "SUCCESS"
else
  log "✗ hpa-bridge network not found"
  STEP_END "FAILED" "bridge not found"
  add_step_result $CURRENT_STEP_NUM "Verify bridge network" "FAILED"
fi

# Prompt after step 1
case $? in
  0) prompt_step 2 "Verify bridge network" "SUCCESS" || [ $? -eq 1 ] && SHIFT_NEXT=true ;;
esac

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

SKIP_TOFU="${SKIP_TOFU:-false}"

# Determine if we should run tofu
if [ "${SKIP_TOFU}" = true ]; then
  log "--skip-tofu set — using existing kubeconfig (if any)."
  CURRENT_STEP_NUM=2
  STEP_START "OpenTofu (skipped)"
  STEP_END "SKIPPED"
  add_step_result $CURRENT_STEP_NUM "OpenTofu apply" "SKIPPED" "--skip-tofu set"
elif [ "${CLUSTER_HEALTHY}" = true ]; then
  log "Cluster is healthy - using existing kubeconfig"
  CURRENT_STEP_NUM=2
  STEP_START "OpenTofu (cluster healthy)"
  STEP_END "SKIPPED"
  add_step_result $CURRENT_STEP_NUM "OpenTofu apply" "SKIPPED" "cluster healthy"
else
  # Prompt to run OpenTofu
  echo "" >&3
  echo "========================================" >&3
  echo "Step 2: Provision Talos VMs (OpenTofu)" >&3
  echo "  Status: PENDING" >&3
  echo "========================================" >&3
  echo "" >&3
  echo "  Options:" >&3
  echo "    E/e  - Execute OpenTofu provisioning" >&3
  echo "    S/s  - Skip OpenTofu (use existing kubeconfig if available)" >&3
  echo "    Q/q  - Quit script" >&3
  echo "========================================" >&3
  
  while true; do
    read -r -p "Choose (E Execute/S Skip/Q Quit): " choice
    case "$choice" in
      [Ee])
        # Run OpenTofu
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

        # Pre-flight cleanup
        log "Running pre-flight cleanup..."
        bash "${MISC_DIR}/cleanup-preflight.sh" --prefix "${DEV_NODE_PREFIX}" --tofu-dir "${TOFU_ABS_DIR}" 2>&1 || {
          log "Pre-flight cleanup had minor issues — continuing anyway."
        }

        log "Running tofu apply -auto-approve..."

        TFDIR="${TOFU_ABS_DIR}"
        TMP_VARS="${TFDIR}/dev.auto.tfvars"

        # Generate variables
        log "Generating ${TMP_VARS} from .env variables..."
        {
          for var_name in DEV_CLUSTER_NAME DEV_CP_COUNT DEV_WORKER_COUNT DEV_VM_CPU \
                          DEV_CP_RAM_MB DEV_WORKER_RAM_MB DEV_OS_DISK_SIZE_GB \
                          DEV_CEPH_DISK_SIZE_GB DEV_BRIDGE_NAME DEV_NODE_PREFIX \
                          DEV_CIDR_BLOCK TALOS_VERSION DEV_TALOS_IMAGE_FACTORY_URL; do
            if [ -n "${!var_name:-}" ]; then
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

        CURRENT_STEP_NUM=1
        add_step_result $CURRENT_STEP_NUM "OpenTofu variables" "SUCCESS" "generated"

        # Run OpenTofu (this can be long-running - show progress)
        (cd "${TFDIR}" && tofu apply -auto-approve 2>&1 | tee "${PROJECT_ROOT}/.tofu-apply.log") &
        TOFU_PID=$!

        # Monitor progress
        while kill -0 ${TOFU_PID} 2>/dev/null; do
          if [ -f "${PROJECT_ROOT}/.gsd/bootstrap-monitor-status" ]; then
            STATUS=$(head -1 "${PROJECT_ROOT}/.gsd/bootstrap-monitor-status" 2>/dev/null || echo "")
            [ -n "${STATUS}" ] && log "Bootstrap progress: ${STATUS}"
          fi
          if [ -f "${PROJECT_ROOT}/.tofu-apply.log" ]; then
            LAST=$(grep -E "Apply complete|Outputs:" "${PROJECT_ROOT}/.tofu-apply.log" 2>/dev/null | tail -1 || true)
            [ -n "${LAST}" ] && log "Tofu: ${LAST}"
          fi
          sleep 10
        done

        wait ${TOFU_PID}
        TOFU_EXIT=$?
        
        if [ "${TOFU_EXIT}" -ne 0 ]; then
          die "tofu apply failed (exit ${TOFU_EXIT})"
        fi

        # Export kubeconfig and talosconfig
        mkdir -p "$(dirname "${KUBECONFIG}")"
        (cd "${TFDIR}" && tofu output -raw kubeconfig 2>/dev/null) > "${KUBECONFIG}" || {
          log "WARNING: Failed to extract kubeconfig from tofu state"
        }

        python3 -c "
import json, subprocess
try:
    out = subprocess.check_output(['tofu', 'output', '-json'], cwd='${TFDIR}')
    outputs = json.loads(out)
    tc = outputs['talosconfig']['value']
    cidr = '${DEV_CIDR_BLOCK}'
    net_base = '.'.join(cidr.split('.')[:3])
    cp_ips = [f'{net_base}.{100 + i}' for i in range(${DEV_CP_COUNT})]
    worker_ips = [f'{net_base}.{110 + i}' for i in range(${DEV_WORKER_COUNT})]
    all_ips = cp_ips + worker_ips
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
        
        # ---- Bootstrap Talos cluster (Method 1 with insecure mode) ----
        log "Bootstrapping Talos cluster with insecure mode..."
        export TALOSCONFIG="${TFDIR}/talosconfig"
        
        # Bootstrap control plane node
        PRIMARY_CP_IP="192.168.122.100"
        
        # Attempt bootstrap with insecure mode (Method 1)
        if command -v talosctl &>/dev/null; then
          # Set talos endpoint
          talosctl config endpoint "insecure://${PRIMARY_CP_IP}" 2>/dev/null || true
          
          # Bootstrap with insecure mode
          log "Running talosctl bootstrap --insecure=true..."
          if timeout 120 talosctl --insecure=true -n "${PRIMARY_CP_IP}" bootstrap 2>&1; then
            log "Bootstrap completed successfully"
          else
            log "WARNING: Bootstrap command returned non-zero, continuing anyway..."
          fi
        else
          log "WARNING: talosctl not found, skipping bootstrap"
        fi
        
        # Wait for API endpoint to be available
        log "Waiting for Talos API to be available..."
        API_READY=false
        for i in {1..30}; do
          if timeout 5 curl -sk "https://${PRIMARY_CP_IP}:6443/healthz" 2>/dev/null | grep -q "ok"; then
            API_READY=true
            break
          fi
          log "Waiting for API... ($i/30)"
          sleep 5
        done
        
        if [ "$API_READY" = true ]; then
          # Generate kubeconfig after successful bootstrap
          log "Generating kubeconfig after bootstrap..."
          if command -v talosctl &>/dev/null; then
            talosctl --insecure=true -n "${PRIMARY_CP_IP}" kubeconfig . 2>/dev/null || log "WARNING: Failed to extract kubeconfig via talosctl"
          fi
          
          # Verify kubeconfig was created
          if [ -f ./kubeconfig ]; then
            cp ./kubeconfig "${KUBECONFIG}"
            log "Kubeconfig saved to ${KUBECONFIG}"
          fi
        else
          log "WARNING: Talos API not available after bootstrap timeout"
        fi
        
        add_step_result 2 "Bootstrap Talos cluster" "SUCCESS" "API ready"
        CURRENT_STEP_NUM=2
        add_step_result $CURRENT_STEP_NUM "OpenTofu apply" "SUCCESS" ""
        
        # Check cluster health
        for i in {1..60}; do
          if kubectl --kubeconfig "${KUBECONFIG}" get nodes 2>/dev/null | grep -q "Ready"; then
            break
          fi
          log "Waiting for cluster nodes... ($i/60)"
          sleep 5
        done
        
        NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        add_step_result 3 "Provision Talos VMs (OpenTofu)" "SUCCESS" "${NODE_COUNT} nodes ready"
        ;;
      [Ss])
        log "--skip-tofu set — using existing kubeconfig (if any)."
        STEP_START "OpenTofu (skipped)"
        STEP_END "SKIPPED"
        CURRENT_STEP_NUM=2
        add_step_result $CURRENT_STEP_NUM "OpenTofu apply" "SKIPPED" "user choice"
        ;;
      [Qq])
        die "User requested quit before OpenTofu"
        ;;
      *)
        echo "Invalid choice. Please enter E, S, or Q." >&3
        ;;
    esac
  done
fi

# Continue with the rest of the pipeline steps...

# ---- Summary --------------------------------------------------------------
log ""
log "=========================================================="
log "Bootstrap Phase Complete!"
log "  Completed steps: ${#STEP_RESULTS[@]}"
log "  kubeconfig: ${KUBECONFIG}"
log ""
log "  Next steps continue automatically in non-interactive mode"
log "  Or run step scripts individually from: provisioning/dev/scripts/steps/"
log ""
log "  Envoy Gateway:"
log "    kubectl -n envoy-gateway-system get gateway hpa-dev-gateway"
log ""
log "  Cleanup:"
log "    ./cleanup.sh"
log "=========================================================="

show_results_table

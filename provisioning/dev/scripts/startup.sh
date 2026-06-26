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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Log setup: capture all output to startup.log at project root --------
STARTUP_LOG="${PROJECT_ROOT}/startup.log"
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
  0. OpenTofu apply (4 Talos VMs + kubeconfig)     [skip with --skip-tofu]
  1. Setup hpa-bridge network
  2. Install Cilium CNI
  3. Install Rook Ceph
  4. Install Harbor
  5. Install Infisical
  6. Install Runtimes (cert-manager, Knative, SpinKube, KeyDB)
  7. Install Casdoor OIDC Provider
  8. Install Casbin gRPC Authorizer
  9. Install Envoy Gateway + Headlamp
  10. Install GitOps (Kargo + ArgoCD)
  11. Deploy Workloads (Welcome + Counter)

Environment:
  .env file at project root sourced automatically

Exit 0 on success, non-zero on first failure.
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- OpenTofu provisioning (skip with --skip-tofu) -----------------------
if [ "${SKIP_TOFU}" = false ] && [ ! -f "${KUBECONFIG}" ]; then
  log "=========================================================="
  log "Step 0: Provision Talos VMs via OpenTofu"
  log "=========================================================="
  log "tofu dir:     ${TOFU_DIR}"
  log "kubeconfig:   ${KUBECONFIG}"
  log ""

  command -v tofu >/dev/null 2>&1 || die "OpenTofu (tofu) not found in PATH"

  TOFU_ABS_DIR="$(cd "${TOFU_DIR}" 2>/dev/null && pwd)"
  if [ -z "${TOFU_ABS_DIR}" ]; then
    die "OpenTofu directory not found at ${TOFU_DIR}"
  fi

  # tofu init if needed
  if [ ! -f "${TOFU_ABS_DIR}/.terraform.lock.hcl" ]; then
    log "Running tofu init..."
    (cd "${TOFU_ABS_DIR}" && tofu init) || die "tofu init failed"
  fi

  log "Running tofu apply -auto-approve (creates 4 Talos VMs)..."
  log "  This takes ~5-8 minutes..."

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

  (cd "${TFDIR}" && tofu apply -auto-approve) || {
    log "FAILED: Contents of ${TMP_VARS}:"
    if [ -f "${TMP_VARS}" ]; then
      while IFS= read -r line; do log "  ${line}"; done < "${TMP_VARS}"
    else
      log "  (file was not created — no env vars were set)"
    fi
    rm -f "${TMP_VARS}"
    die "tofu apply failed"
  }

  log "tofu apply completed successfully."

  log "tofu apply completed successfully."
elif [ "${SKIP_TOFU}" = false ] && [ -f "${KUBECONFIG}" ]; then
  log "kubeconfig already exists — skipping tofu apply."
else
  log "--skip-tofu set — using existing kubeconfig (if any)."
fi

# ---- Verify cluster access ------------------------------------------------
log "=========================================================="
log "HPA Dev Cluster — Full Bootstrap Pipeline"
log "=========================================================="
log "kubeconfig: ${KUBECONFIG}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v helm >/dev/null 2>&1   || die "helm not found"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# Quick connectivity check
if ! kubectl get nodes > /dev/null 2>&1; then
  die "Cannot reach cluster via kubeconfig at ${KUBECONFIG}"
fi
log "Cluster reachable."
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
log "Nodes: ${NODE_COUNT}"

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
  shift 3
  log ""
  log "========== Step ${num}/${TOTAL_STEPS}: ${name} =========="
  if bash "${script}" "$@" 2>&1; then
    log "Step ${num}: ${name} — DONE"
  else
    die "Step ${num}: ${name} — FAILED (exit code $?)"
  fi
}

TOTAL_STEPS=12

# Step 0 (tofu) is already done above

step 1 "Setup hpa-bridge network"   ./setup-bridge.sh
step 2 "Install Cilium CNI"         ./install-cilium.sh
step 3 "Install Rook Ceph"          ./install-rook-ceph.sh
step 4 "Install Harbor"             ./install-harbor.sh
step 5 "Install Infisical"          ./install-infisical.sh
step 6 "Install Runtimes (cert-manager, Knative, SpinKube, KeyDB)" \
                                     ./install-runtimes.sh
step 7 "Install Casdoor OIDC Provider" \
                                     ./install-casdoor.sh
step 8 "Install Casbin gRPC Authorizer" \
                                     ./install-casbin.sh
step 9 "Install Envoy Gateway + Headlamp" \
                                     ./install-gateway.sh
step 10 "Install GitOps (Kargo + ArgoCD)" \
                                     ./install-gitops.sh
step 11 "Deploy Workloads (Welcome + Counter)" \
                                     ./install-workloads.sh

# ---- Run verification scripts ---------------------------------------------
log ""
log "========== Running Verification Scripts =========="

# Check static artifacts first
log "--- verify-manifests.sh (static) ---"
bash ./verify-manifests.sh 2>&1 || log "  (non-fatal) Some repos may be unreachable"

# Runtime checks
for verify_script in verify-cilium.sh verify-ceph.sh verify-harbor.sh \
                     verify-infisical.sh verify-runtimes.sh verify-casdoor.sh \
                     verify-casbin.sh verify-gateway.sh verify-gitops.sh; do
  log "--- ${verify_script} ---"
  bash "./${verify_script}" 2>&1 || log "  (non-fatal) Some checks may need more time"
done

# Workload verification with Envoy IP
if [ -z "${ENVOY_IP}" ]; then
  log "--- verify-workloads.sh (auto-discover Envoy IP) ---"
  bash ./verify-workloads.sh 2>&1 || log "  (non-fatal) Workload verification may need Envoy IP"
else
  log "--- verify-workloads.sh (Envoy IP: ${ENVOY_IP}) ---"
  bash ./verify-workloads.sh --envoy-ip "${ENVOY_IP}" 2>&1 || log "  (non-fatal) Some workload checks may need more time"
fi

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

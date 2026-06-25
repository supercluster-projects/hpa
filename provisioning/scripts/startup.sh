#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# startup.sh — Full dev environment bootstrap in one shot
#
# Orchestrates the complete pipeline from bare metal to a running HPA dev
# cluster. Run this after `tofu apply -auto-approve` has provisioned the
# Talos VMs. Every step is idempotent — safe to re-run if something fails.
#
# Usage: ./startup.sh [--kubeconfig <path>] [--envoy-ip <ip>] [--help]
#
# Options:
#   --kubeconfig PATH   Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
#   --envoy-ip IP       Envoy LB IP for endpoint verification (auto-detected if omitted).
#                       Must be within DEV_LB_POOL_CIDR (.208/28 by default).
#   --help, -h          Show this help message
#
# Environment:
#   .env file at project root sourced automatically if present (see .env.example)
#   CLI flags override env vars which override script defaults
#
#   INFISICAL_ENCRYPTION_KEY   Must be set in .env (no default, generate with openssl rand -hex 32)
#   INFISICAL_ADMIN_PASSWORD   Must be set in .env (no default)
#   INFISICAL_AUTH_SECRET      Must be set in .env (no default, generate with openssl rand -hex 64)
#
# Exit code: 0 on success, non-zero on first failure
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Config ---------------------------------------------------------------
ENVOY_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)  KUBECONFIG="$2";  shift 2 ;;
    --envoy-ip)     ENVOY_IP="$2";    shift 2 ;;
    --help|-h)
      cat <<HELP
Usage: $(basename "$0") [options]

Full dev environment bootstrap in one shot.

Prerequisites:
  1. tofu apply has already provisioned Talos VMs
  2. kubectl can reach the cluster via kubeconfig
  3. Configure .env at project root (see .env.example for all variables)

Steps:
  1. setup-bridge.sh       4. install-harbor.sh      7. install-gateway.sh
  2. install-cilium.sh     5. install-infisical.sh   8. install-gitops.sh
  3. install-rook-ceph.sh  6. install-runtimes.sh    9. install-workloads.sh

Exit 0 on success, non-zero on first failure.
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

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

# ---- Auto-generate Infisical secrets if not set ---------------------------
if [ -z "${INFISICAL_ENCRYPTION_KEY:-}" ]; then
  export INFISICAL_ENCRYPTION_KEY="$(openssl rand -hex 32)"
  log "INFISICAL_ENCRYPTION_KEY: auto-generated"
fi
if [ -z "${INFISICAL_ADMIN_PASSWORD:-}" ]; then
  export INFISICAL_ADMIN_PASSWORD="$(openssl rand -base64 16)"
  log "INFISICAL_ADMIN_PASSWORD: auto-generated"
fi
if [ -z "${INFISICAL_AUTH_SECRET:-}" ]; then
  export INFISICAL_AUTH_SECRET="$(openssl rand -hex 64)"
  log "INFISICAL_AUTH_SECRET: auto-generated"
fi

# ---- Run pipeline ---------------------------------------------------------
cd "${SCRIPT_DIR}"

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

TOTAL_STEPS=9

step 1 "Setup hpa-bridge network"   ./setup-bridge.sh
step 2 "Install Cilium CNI"         ./install-cilium.sh
step 3 "Install Rook Ceph"          ./install-rook-ceph.sh
step 4 "Install Harbor"             ./install-harbor.sh
step 5 "Install Infisical"          ./install-infisical.sh
step 6 "Install Runtimes (cert-manager, Knative, SpinKube, KeyDB)" \
                                     ./install-runtimes.sh
step 7 "Install Envoy Gateway + Headlamp" \
                                     ./install-gateway.sh
step 8 "Install GitOps (Kargo + ArgoCD)" \
                                     ./install-gitops.sh
step 9 "Deploy Workloads (Welcome + Counter)" \
                                     ./install-workloads.sh

# ---- Run verification scripts ---------------------------------------------
log ""
log "========== Running Verification Scripts =========="

# Check static artifacts first
log "--- verify-manifests.sh (static) ---"
bash ./verify-manifests.sh 2>&1 || log "  (non-fatal) Some repos may be unreachable"

# Runtime checks
for verify_script in verify-cilium.sh verify-ceph.sh verify-harbor.sh \
                     verify-infisical.sh verify-runtimes.sh verify-gateway.sh \
                     verify-gitops.sh; do
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

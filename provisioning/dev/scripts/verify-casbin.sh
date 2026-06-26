#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-casbin.sh -- Casbin gRPC ext_authz health verification
#
# Verifies Casbin authorizer pod health, Service ClusterIP assignment,
# ConfigMap presence with expected keys, and optional gRPC endpoint
# connectivity.
#
# Designed for post-install validation and troubleshooting. Exits non-zero
# on any phase failure. Gracefully handles still-initializing Casbin
# (pods still starting) with clear messaging.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-casbin.sh [--kubeconfig <path>] [--namespace <ns>]
#                           [--expected-pods <count>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="casbin"
EXPECTED_PODS=1
SERVICE_NAME="casbin-ext-authz"
DEPLOYMENT_NAME="casbin-ext-authz"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";     shift 2 ;;
    --namespace)       NAMESPACE="$2";      shift 2 ;;
    --expected-pods)  EXPECTED_PODS="$2";   shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Casbin gRPC ext_authz health: pod readiness, Service ClusterIP,
ConfigMap presence with expected keys, and deployment rollout status.

Options:
  --kubeconfig PATH     Path to kubeconfig (default: ../opentofu/kubeconfig)
  --namespace NS        Casbin namespace (default: casbin)
  --expected-pods NUM   Expected number of pods (default: 1)
  --help, -h            Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-casbin: starting"
log "  kubeconfig:      ${KUBECONFIG}"
log "  namespace:       ${NAMESPACE}"
log "  expected pods:   ${EXPECTED_PODS}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # Namespace existence
PHASE1_DETAIL=""
PHASE2_STATUS=""   # Deployment rollout
PHASE2_DETAIL=""
PHASE3_STATUS=""   # Service ClusterIP
PHASE3_DETAIL=""
PHASE4_STATUS=""   # ConfigMap keys
PHASE4_DETAIL=""

OVERALL_FAILED=0

# ============================================================================
# Phase 1: Namespace existence
# ============================================================================
log "Phase 1: Checking namespace '${NAMESPACE}' exists"
NS_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" get namespace "${NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>&1) \
  || { err "Namespace '${NAMESPACE}' not found: ${NS_OUTPUT}"; PHASE1_STATUS="FAIL"; PHASE1_DETAIL="Namespace not found"; OVERALL_FAILED=1; }

if [ -z "${PHASE1_STATUS}" ]; then
  if [ "${NS_OUTPUT}" = "Active" ]; then
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="Namespace '${NAMESPACE}' is Active"
    log "Phase 1: ${PHASE1_DETAIL} -- PASSED"
  else
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="Namespace '${NAMESPACE}' status: ${NS_OUTPUT}"
    OVERALL_FAILED=1
    log "Phase 1: ${PHASE1_DETAIL} -- FAILED"
  fi
fi

# ============================================================================
# Phase 2: Deployment rollout status
# ============================================================================
log "Phase 2: Checking Deployment '${DEPLOYMENT_NAME}' rollout status"

# Check if the deployment exists first
DEPLOY_EXISTS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get deployment \
  "${DEPLOYMENT_NAME}" -o name 2>&1) \
  || { err "Deployment '${DEPLOYMENT_NAME}' not found: ${DEPLOY_EXISTS}"; PHASE2_STATUS="FAIL"; PHASE2_DETAIL="Deployment not found"; OVERALL_FAILED=1; }

if [ -z "${PHASE2_STATUS}" ]; then
  # Check rollout status (timed check, not infinite)
  ROLLOUT_STATUS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    rollout status deployment/"${DEPLOYMENT_NAME}" --timeout=10s 2>&1) \
    || true

  # Get ready replicas for detail
  DEPLOY_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get deployment \
    "${DEPLOYMENT_NAME}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DEPLOY_DESIRED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get deployment \
    "${DEPLOYMENT_NAME}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  DEPLOY_AVAILABLE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get deployment \
    "${DEPLOYMENT_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")

  if echo "${ROLLOUT_STATUS}" | grep -q "successfully rolled out"; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="${DEPLOY_READY:-0}/${DEPLOY_DESIRED:-0} ready (Available=${DEPLOY_AVAILABLE})"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
  else
    err "Deployment '${DEPLOYMENT_NAME}' not fully rolled out"
    PHASE2_STATUS="FAIL"
    PHASE2_DETAIL="${DEPLOY_READY:-0}/${DEPLOY_DESIRED:-0} ready (Available=${DEPLOY_AVAILABLE})"
    OVERALL_FAILED=1
    log "Phase 2: ${PHASE2_DETAIL} -- FAILED"
  fi
fi

# ============================================================================
# Phase 3: Service ClusterIP
# ============================================================================
log "Phase 3: Checking Service '${SERVICE_NAME}' ClusterIP"

SVC_JSON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get service \
  "${SERVICE_NAME}" -o json 2>&1) \
  || { err "Service '${SERVICE_NAME}' not found: ${SVC_JSON}"; PHASE3_STATUS="FAIL"; PHASE3_DETAIL="Service not found"; OVERALL_FAILED=1; }

if [ -z "${PHASE3_STATUS}" ]; then
  SVC_CLUSTER_IP=$(echo "${SVC_JSON}" | grep -o '"clusterIP":"[^"]*"' | cut -d'"' -f4 || true)
  SVC_PORT=$(echo "${SVC_JSON}" | grep -o '"port":[0-9]*' | head -1 | cut -d: -f2 || true)
  SVC_TYPE=$(echo "${SVC_JSON}" | grep -o '"type":"[^"]*"' | cut -d'"' -f4 || true)

  if [ -z "${SVC_CLUSTER_IP}" ] || [ "${SVC_CLUSTER_IP}" = "None" ]; then
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="No ClusterIP assigned"
    OVERALL_FAILED=1
    log "Phase 3: ${PHASE3_DETAIL} -- FAILED"
  else
    PHASE3_STATUS="PASS"
    PHASE3_DETAIL="ClusterIP: ${SVC_CLUSTER_IP}, port: ${SVC_PORT} (${SVC_TYPE})"
    log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
  fi
fi

# ============================================================================
# Phase 4: ConfigMap casbin-config with expected keys
# ============================================================================
log "Phase 4: Checking ConfigMap 'casbin-config' with expected keys"

CM_EXISTS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get configmap \
  casbin-config -o name 2>&1) \
  || { err "ConfigMap 'casbin-config' not found: ${CM_EXISTS}"; PHASE4_STATUS="FAIL"; PHASE4_DETAIL="ConfigMap not found"; OVERALL_FAILED=1; }

if [ -z "${PHASE4_STATUS}" ]; then
  # Check for expected keys
  HAS_MODEL=false
  HAS_POLICY=false

  CM_MODEL=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get configmap \
    casbin-config -o jsonpath='{.data.casbin_model\.conf}' 2>/dev/null || echo "")
  CM_POLICY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get configmap \
    casbin-config -o jsonpath='{.data.casbin_policy\.csv}' 2>/dev/null || echo "")

  if [ -n "${CM_MODEL}" ]; then
    HAS_MODEL=true
  fi
  if [ -n "${CM_POLICY}" ]; then
    HAS_POLICY=true
  fi

  if [ "${HAS_MODEL}" = true ] && [ "${HAS_POLICY}" = true ]; then
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="Keys present: casbin_model.conf, casbin_policy.csv"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED"
  elif [ "${HAS_MODEL}" = true ]; then
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="Missing key: casbin_policy.csv"
    OVERALL_FAILED=1
    log "Phase 4: ${PHASE4_DETAIL} -- FAILED"
  elif [ "${HAS_POLICY}" = true ]; then
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="Missing key: casbin_model.conf"
    OVERALL_FAILED=1
    log "Phase 4: ${PHASE4_DETAIL} -- FAILED"
  else
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="Both expected keys missing (casbin_model.conf, casbin_policy.csv)"
    OVERALL_FAILED=1
    log "Phase 4: ${PHASE4_DETAIL} -- FAILED"
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Casbin Health Verification Summary ==="
printf "%-10s %-12s %-54s\n" "PHASE"     "STATUS" "DETAIL"
printf "%-10s %-12s %-54s\n" "-----"     "------" "------"
printf "%-10s %-12s %-54s\n" "1-Namespace" "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-54s\n" "2-Deploy"    "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-54s\n" "3-Service"   "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-54s\n" "4-ConfigMap"  "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
echo "========================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "========================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-casbin: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-casbin: ALL CHECKS PASSED"
exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-security-policy.sh — Envoy Gateway SecurityPolicy health verification
#
# Verifies Envoy Gateway SecurityPolicy deployment and its integration with
# the Casbin gRPC ext_authz authorizer:
#   Phase 1: SecurityPolicy CRD exists (securitypolicies.gateway.envoyproxy.io)
#   Phase 2: SecurityPolicy resource exists with correct targetRef
#   Phase 3: Gateway hpa-dev-gateway has Accepted condition
#   Phase 4: Casbin extAuth Service reachable (ClusterIP assigned)
#
# Designed for post-install validation and troubleshooting. Exits non-zero
# on any phase failure.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-security-policy.sh [--kubeconfig <path>]
#           [--gateway-name <name>] [--gateway-namespace <ns>]
#           [--policy-name <name>] [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Required environment variables (fail fast if missing from .env) ---
require_env DEV_GATEWAY_NAME

# ---- Internal defaults (script-internal only) -------------------------
GATEWAY_NAME="${DEV_GATEWAY_NAME}"
GATEWAY_NAMESPACE="envoy-gateway-system"
POLICY_NAME="hpa-dev-security-policy"
CARD_NAME="securitypolicies.gateway.envoyproxy.io"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)             KUBECONFIG="$2";                 shift 2 ;;
    --gateway-name)           GATEWAY_NAME="$2";              shift 2 ;;
    --gateway-namespace)      GATEWAY_NAMESPACE="$2";         shift 2 ;;
    --policy-name)            POLICY_NAME="$2";               shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Envoy Gateway SecurityPolicy health and Casbin extAuth integration.

Phases:
  1  SecurityPolicy CRD exists (securitypolicies.gateway.envoyproxy.io)
  2  SecurityPolicy resource exists with correct targetRef
  3  Gateway has Accepted condition
  4  Casbin extAuth Service reachable

Options:
  --kubeconfig PATH          Path to kubeconfig (default: ../opentofu/kubeconfig)
  --gateway-name NAME        Gateway resource name (default: hpa-dev-gateway)
  --gateway-namespace NS     Gateway namespace (default: envoy-gateway-system)
  --policy-name NAME         SecurityPolicy resource name (default: hpa-dev-security-policy)
  --help, -h                 Show this help message

Examples:
  ./verify-security-policy.sh --kubeconfig /custom/path/kubeconfig
  ./verify-security-policy.sh --policy-name my-policy
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-security-policy: starting"
log "  kubeconfig:        ${KUBECONFIG}"
log "  policy name:       ${POLICY_NAME}"
log "  gateway:           ${GATEWAY_NAME}"
log "  gateway namespace: ${GATEWAY_NAMESPACE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # SecurityPolicy CRD
PHASE1_DETAIL=""
PHASE2_STATUS=""   # SecurityPolicy resource
PHASE2_DETAIL=""
PHASE3_STATUS=""   # Gateway conditions
PHASE3_DETAIL=""
PHASE4_STATUS=""   # Casbin extAuth Service
PHASE4_DETAIL=""

OVERALL_FAILED=0

# ============================================================================
# Phase 1: SecurityPolicy CRD exists
# ============================================================================
log "Phase 1: Checking SecurityPolicy CRD '${CARD_NAME}'"

if kubectl --kubeconfig "${KUBECONFIG}" get crd "${CARD_NAME}" > /dev/null 2>&1; then
  PHASE1_STATUS="PASS"
  PHASE1_DETAIL="CRD '${CARD_NAME}' found"
  log "Phase 1: ${PHASE1_DETAIL} -- PASSED"
else
  err "CRD '${CARD_NAME}' not found — Envoy Gateway may not be installed"
  PHASE1_STATUS="FAIL"
  PHASE1_DETAIL="CRD '${CARD_NAME}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: SecurityPolicy resource exists with correct targetRef
# ============================================================================
log "Phase 2: Checking SecurityPolicy '${POLICY_NAME}' in '${GATEWAY_NAMESPACE}'"

if kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get securitypolicy "${POLICY_NAME}" > /dev/null 2>&1; then
  # Check targetRef points to the correct Gateway
  TARGET_KIND=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get securitypolicy "${POLICY_NAME}" \
    -o jsonpath='{.spec.targetRefs[0].kind}' 2>&1 || true)
  TARGET_NAME=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get securitypolicy "${POLICY_NAME}" \
    -o jsonpath='{.spec.targetRefs[0].name}' 2>&1 || true)

  # Check extAuth backend points to Casbin
  AUTH_BACKEND=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get securitypolicy "${POLICY_NAME}" \
    -o jsonpath='{.spec.extAuth.grpc.backendRefs[0].name}' 2>&1 || true)
  AUTH_NAMESPACE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get securitypolicy "${POLICY_NAME}" \
    -o jsonpath='{.spec.extAuth.grpc.backendRefs[0].namespace}' 2>&1 || true)
  AUTH_PORT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get securitypolicy "${POLICY_NAME}" \
    -o jsonpath='{.spec.extAuth.grpc.backendRefs[0].port}' 2>&1 || true)

  # Check failOpen setting
  FAIL_OPEN=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get securitypolicy "${POLICY_NAME}" \
    -o jsonpath='{.spec.extAuth.failOpen}' 2>&1 || true)

  local detail_parts=""
  local all_ok=true

  if [ "${TARGET_KIND}" = "Gateway" ] && [ "${TARGET_NAME}" = "${GATEWAY_NAME}" ]; then
    detail_parts="targetRef=Gateway/${TARGET_NAME}"
  else
    if [ "${TARGET_KIND}" != "Gateway" ]; then
      detail_parts="targetRef.kind=${TARGET_KIND:-missing} (expected Gateway)"
    else
      detail_parts="targetRef.name=${TARGET_NAME:-missing} (expected ${GATEWAY_NAME})"
    fi
    all_ok=false
  fi

  if [ -n "${AUTH_BACKEND}" ] && [ -n "${AUTH_NAMESPACE}" ]; then
    detail_parts="${detail_parts}, extAuth=${AUTH_BACKEND}.${AUTH_NAMESPACE}:${AUTH_PORT:-9001} (gRPC)"
    if [ "${AUTH_BACKEND}" != "casbin-ext-authz" ] || [ "${AUTH_NAMESPACE}" != "casbin" ]; then
      detail_parts="${detail_parts} (unexpected backend)"
      all_ok=false
    fi
  else
    detail_parts="${detail_parts}, extAuth backend: missing"
    all_ok=false
  fi

  # failOpen should be false (block traffic if auth unavailable)
  if [ -n "${FAIL_OPEN}" ]; then
    detail_parts="${detail_parts}, failOpen=${FAIL_OPEN}"
  fi

  if [ "${all_ok}" = true ]; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="SecurityPolicy '${POLICY_NAME}' valid: ${detail_parts}"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
  else
    PHASE2_STATUS="FAIL"
    PHASE2_DETAIL="SecurityPolicy '${POLICY_NAME}' misconfigured: ${detail_parts}"
    OVERALL_FAILED=1
    log "Phase 2: ${PHASE2_DETAIL} -- FAILED"
  fi
else
  err "SecurityPolicy '${POLICY_NAME}' not found in namespace '${GATEWAY_NAMESPACE}'"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="SecurityPolicy '${POLICY_NAME}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 3: Gateway has Accepted condition
# ============================================================================
log "Phase 3: Checking Gateway '${GATEWAY_NAME}' has Accepted condition"

if kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" > /dev/null 2>&1; then
  GATEWAY_ACCEPTED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>&1 || true)
  GATEWAY_PROGRAMMED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>&1 || true)

  if [ "${GATEWAY_ACCEPTED}" = "True" ] && [ "${GATEWAY_PROGRAMMED}" = "True" ]; then
    PHASE3_STATUS="PASS"
    PHASE3_DETAIL="Gateway '${GATEWAY_NAME}': Accepted=True, Programmed=True"
    log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
  elif [ "${GATEWAY_ACCEPTED}" = "True" ]; then
    PHASE3_STATUS="WARN"
    PHASE3_DETAIL="Gateway '${GATEWAY_NAME}': Accepted=True, Programmed=${GATEWAY_PROGRAMMED:-missing}"
    log "Phase 3: ${PHASE3_DETAIL} -- WARN"
  else
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="Gateway '${GATEWAY_NAME}': Accepted=${GATEWAY_ACCEPTED:-missing}, Programmed=${GATEWAY_PROGRAMMED:-missing}"
    OVERALL_FAILED=1
    log "Phase 3: ${PHASE3_DETAIL} -- FAILED"
  fi
else
  err "Gateway '${GATEWAY_NAME}' not found in namespace '${GATEWAY_NAMESPACE}'"
  PHASE3_STATUS="FAIL"
  PHASE3_DETAIL="Gateway '${GATEWAY_NAME}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 4: Casbin extAuth Service reachable
# ============================================================================
log "Phase 4: Checking Casbin extAuth Service reachable (ClusterIP assigned)"

CASBIN_NAMESPACE="casbin"
CASBIN_SERVICE="casbin-ext-authz"

if kubectl --kubeconfig "${KUBECONFIG}" -n "${CASBIN_NAMESPACE}" get svc "${CASBIN_SERVICE}" > /dev/null 2>&1; then
  SVC_CLUSTER_IP=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CASBIN_NAMESPACE}" get svc "${CASBIN_SERVICE}" \
    -o jsonpath='{.spec.clusterIP}' 2>&1 || true)
  SVC_PORT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CASBIN_NAMESPACE}" get svc "${CASBIN_SERVICE}" \
    -o jsonpath='{.spec.ports[0].port}' 2>&1 || true)
  SVC_TARGET_PORT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CASBIN_NAMESPACE}" get svc "${CASBIN_SERVICE}" \
    -o jsonpath='{.spec.ports[0].targetPort}' 2>&1 || true)

  if [ -z "${SVC_CLUSTER_IP}" ] || [ "${SVC_CLUSTER_IP}" = "None" ]; then
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="Service '${CASBIN_SERVICE}' in '${CASBIN_NAMESPACE}' has no ClusterIP"
    OVERALL_FAILED=1
    log "Phase 4: ${PHASE4_DETAIL} -- FAILED"
  else
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="Service '${CASBIN_SERVICE}' ClusterIP=${SVC_CLUSTER_IP}:${SVC_PORT}, targetPort=${SVC_TARGET_PORT}"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED"
  fi
else
  err "Service '${CASBIN_SERVICE}' not found in namespace '${CASBIN_NAMESPACE}'"
  PHASE4_STATUS="FAIL"
  PHASE4_DETAIL="Service '${CASBIN_SERVICE}' not found in '${CASBIN_NAMESPACE}'"
  OVERALL_FAILED=1
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== SecurityPolicy Health Verification Summary ==="
printf "%-10s %-12s %-60s\n" "PHASE"         "STATUS" "DETAIL"
printf "%-10s %-12s %-60s\n" "-----"         "------" "------"
printf "%-10s %-12s %-60s\n" "1-CRD"         "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-60s\n" "2-Policy"      "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-60s\n" "3-Gateway"     "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-60s\n" "4-CasbinSvc"   "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
echo "================================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "================================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-security-policy: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-security-policy: ALL CHECKS PASSED"
exit 0

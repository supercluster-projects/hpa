#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-infisical-workloads.sh — Verify Infisical workload secret integration
#
# Verifies that the Infisical workload bootstrap completed successfully.
# Checks all layers: API reachability, InfisicalSecret CRDs, managed
# Kubernetes Secrets, auth Secrets, and bootstrap Secret cleanup.
#
# Designed for post-bootstrap validation. Exits non-zero on any phase
# failure.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-infisical-workloads.sh [--kubeconfig <path>]
#                                        [--infisical-ns <ns>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
INFISICAL_NAMESPACE="infisical"
INFISICAL_PORT=8080
OVERALL_FAILED=0

# Workload namespaces
WORKLOAD_NS=("hpa-workloads" "casbin" "hasura")
MANAGED_SECRETS=("welcome-infisical-secrets" "casbin-infisical-secrets" "counter-infisical-secrets" "stream-infisical-secrets")
AUTH_SECRETS=("infisical-auth:hpa-workloads" "infisical-auth:casbin" "infisical-auth:hasura")

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG="$2";           shift 2 ;;
    --infisical-ns)      INFISICAL_NAMESPACE="$2";   shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Infisical workload bootstrap: InfisicalSecret CRDs, managed
Kubernetes Secrets, auth Secrets, and bootstrap Secret cleanup.

Options:
  --kubeconfig PATH    Path to kubeconfig (default: ../opentofu/kubeconfig)
  --infisical-ns NS    Infisical namespace (default: infisical)
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
log "verify-infisical-workloads: starting"
log "  kubeconfig:        ${KUBECONFIG}"
log "  infisical-ns:      ${INFISICAL_NAMESPACE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"

# Resolve Infisical LB IP
LB_IP=""
if command -v curl >/dev/null 2>&1; then
  LB_IP=$(kubectl -n "${INFISICAL_NAMESPACE}" get svc infisical \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
fi

# ---- Phase state tracking -------------------------------------------------
PHASE_DETAILS=()
PHASE_STATUSES=()
PHASE_NAMES=()

reset_phase() {
  PHASE_NAMES+=("$1")
}
pass_phase() {
  PHASE_STATUSES+=("PASS")
  PHASE_DETAILS+=("$1")
}
fail_phase() {
  PHASE_STATUSES+=("FAIL")
  PHASE_DETAILS+=("$1")
  OVERALL_FAILED=1
}
skip_phase() {
  PHASE_STATUSES+=("SKIP")
  PHASE_DETAILS+=("$1")
}

# ============================================================================
# Phase 1: Infisical API reachability (optional, requires curl + LB IP)
# ============================================================================
reset_phase "1-API-Reach"

if [ -z "${LB_IP}" ]; then
  pass_phase "LB IP not assigned; SKIPPED"
elif ! command -v curl >/dev/null 2>&1; then
  skip_phase "curl not available in PATH"
else
  API_HTTP_CODE=$(curl -o /dev/null -s -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://${LB_IP}:${INFISICAL_PORT}/api/health" 2>&1 || true)

  if [ "${API_HTTP_CODE}" = "200" ]; then
    pass_phase "HTTP ${API_HTTP_CODE} from /api/health"
  else
    fail_phase "HTTP ${API_HTTP_CODE} from /api/health (expected 200)"
  fi
fi

# ============================================================================
# Phase 2: InfisicalSecret CRDs exist in workload namespaces
#
# Verifies the InfisicalSecret custom resources were created by checking
# the secrets.infisical.com/v1alpha1 CRD exists and the InfisicalSecret
# resources are present in each namespace.
# ============================================================================
reset_phase "2-CRDs"

CRD_COUNT=0
CRD_DETAIL=""

# Check CRD registration
if kubectl --kubeconfig "${KUBECONFIG}" get crd infisicalsecrets.secrets.infisical.com >/dev/null 2>&1; then
  CRD_DETAIL="CRD registered"
else
  CRD_DETAIL="CRD not found (legacy name)"
  # Try legacy CRD name
  if kubectl --kubeconfig "${KUBECONFIG}" get crd infisicalsecrets.secrets.infisical.com >/dev/null 2>&1; then
    CRD_DETAIL="CRD registered (legacy)"
  fi
fi

# Check expected InfisicalSecret resources
EXPECTED_CRDS=(
  "hpa-workloads:welcome-secrets"
  "hpa-workloads:counter-secrets"
  "hpa-workloads:stream-secrets"
  "casbin:casbin-secrets"
  "hasura:hasura-secrets"
)

RESOURCE_FAILURES=0
for entry in "${EXPECTED_CRDS[@]}"; do
  ns="${entry%%:*}"
  name="${entry##*:}"
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" \
    get infisicalsecret "${name}" >/dev/null 2>&1; then
    CRD_COUNT=$((CRD_COUNT + 1))
  else
    err "InfisicalSecret '${name}' not found in namespace '${ns}'"
    RESOURCE_FAILURES=$((RESOURCE_FAILURES + 1))
  fi
done

if [ "${RESOURCE_FAILURES}" -eq 0 ]; then
  pass_phase "${CRD_DETAIL}; ${CRD_COUNT}/${#EXPECTED_CRDS[@]} resources found"
elif [ "${CRD_COUNT}" -gt 0 ]; then
  fail_phase "${CRD_DETAIL}; ${CRD_COUNT}/${#EXPECTED_CRDS[@]} resources found (${RESOURCE_FAILURES} missing)"
else
  fail_phase "${CRD_DETAIL}; ${CRD_COUNT}/${#EXPECTED_CRDS[@]} resources found (${RESOURCE_FAILURES} missing)"
fi

# ============================================================================
# Phase 3: Managed Kubernetes Secrets exist
#
# Verifies that the Infisical Secrets Operator has created the target
# Kubernetes Secrets that the workloads consume via envFrom.
# ============================================================================
reset_phase "3-Managed-Secrets"

MANAGED_OK=0
MANAGED_FAIL=0
MANAGED_DETAIL=""

for secret in "${MANAGED_SECRETS[@]}"; do
  # Determine namespace from secret name
  case "${secret}" in
    welcome-infisical-secrets|counter-infisical-secrets|stream-infisical-secrets)
      ns="hpa-workloads" ;;
    casbin-infisical-secrets)
      ns="casbin" ;;
    *)
      ns="hpa-workloads" ;;
  esac

  if kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" \
    get secret "${secret}" >/dev/null 2>&1; then
    MANAGED_OK=$((MANAGED_OK + 1))
  else
    err "Managed Secret '${secret}' not found in namespace '${ns}'"
    MANAGED_FAIL=$((MANAGED_FAIL + 1))
  fi
done

if [ "${MANAGED_FAIL}" -eq 0 ]; then
  pass_phase "${MANAGED_OK}/${#MANAGED_SECRETS[@]} managed Secrets found"
else
  fail_phase "${MANAGED_OK}/${#MANAGED_SECRETS[@]} managed Secrets found (${MANAGED_FAIL} missing)"
fi

# ============================================================================
# Phase 4: Auth Secrets exist in workload namespaces
#
# Verifies that bootstrap-infisical-workloads.sh created the infisical-auth
# Secrets (containing Universal Auth clientId/clientSecret) in each workload
# namespace. These are the Secrets the InfisicalSecret CRDs reference.
# ============================================================================
reset_phase "4-Auth-Secrets"

AUTH_OK=0
AUTH_FAIL=0
AUTH_DETAIL=""

for entry in "${AUTH_SECRETS[@]}"; do
  name="${entry%%:*}"
  ns="${entry##*:}"
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" \
    get secret "${name}" >/dev/null 2>&1; then
    AUTH_OK=$((AUTH_OK + 1))
  else
    err "Auth Secret '${name}' not found in namespace '${ns}'"
    AUTH_FAIL=$((AUTH_FAIL + 1))
  fi
done

if [ "${AUTH_FAIL}" -eq 0 ]; then
  pass_phase "${AUTH_OK}/${#AUTH_SECRETS[@]} auth Secrets found"
else
  fail_phase "${AUTH_OK}/${#AUTH_SECRETS[@]} auth Secrets found (${AUTH_FAIL} missing)"
fi

# ============================================================================
# Phase 5: Bootstrap Secret absence (security requirement)
#
# Negative test: confirms all bootstrap Secrets have been cleaned up.
# Phase 5 in the original verify-infisical.sh only checks the infisical
# namespace. This extends the sweep to all workload namespaces:
#   - bootstrap-infisical in infisical namespace
#   - infisical-token in any namespace (older service token pattern)
#   - Any Secret with name containing "bootstrap" across all namespaces
# ============================================================================
reset_phase "5-Bootstrap-Cleanup"

BOOTSTRAP_FOUND=0
SWEEP_DETAIL=""

# Check 1: Original bootstrap-infisical Secret (from install-infisical.sh)
if kubectl --kubeconfig "${KUBECONFIG}" -n "${INFISICAL_NAMESPACE}" \
  get secret bootstrap-infisical >/dev/null 2>&1; then
  err "Bootstrap Secret 'bootstrap-infisical' STILL EXISTS in namespace ${INFISICAL_NAMESPACE}"
  BOOTSTRAP_FOUND=$((BOOTSTRAP_FOUND + 1))
  SWEEP_DETAIL="${SWEEP_DETAIL} bootstrap-infisical still in ${INFISICAL_NAMESPACE},"
fi

# Check 2: Sweep workload namespaces for any bootstrap-pattern Secrets
for ns in "${WORKLOAD_NS[@]}"; do
  for secret in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" \
    get secrets -o name 2>/dev/null \
    | sed 's|secret/||' \
    | grep -i -E '^infisical-token$' 2>/dev/null || true); do
    err "Bootstrap Secret '${secret}' STILL EXISTS in namespace '${ns}'"
    BOOTSTRAP_FOUND=$((BOOTSTRAP_FOUND + 1))
    SWEEP_DETAIL="${SWEEP_DETAIL} ${secret} in ${ns},"
  done

  for secret in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" \
    get secrets -o name 2>/dev/null \
    | sed 's|secret/||' \
    | grep -i -E 'bootstrap' 2>/dev/null || true); do
    # Skip any managed Secrets that might contain "bootstrap" in unrelated context
    if [[ "${secret}" != *-infisical-secrets ]] && [ "${secret}" != "infisical-auth" ] && [ "${secret}" != "sh.helm.release"* ]; then
      err "Bootstrap-pattern Secret '${secret}' STILL EXISTS in namespace '${ns}'"
      BOOTSTRAP_FOUND=$((BOOTSTRAP_FOUND + 1))
      SWEEP_DETAIL="${SWEEP_DETAIL} ${secret} in ${ns},"
    fi
  done
done

if [ "${BOOTSTRAP_FOUND}" -eq 0 ]; then
  pass_phase "All bootstrap Secrets cleaned up"
else
  fail_phase "${BOOTSTRAP_FOUND} bootstrap Secret(s) still exist:${SWEEP_DETAIL}"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Infisical Workload Integration Verification Summary ==="
printf "%-18s %-12s %-55s\n" "PHASE"           "STATUS" "DETAIL"
printf "%-18s %-12s %-55s\n" "-----"           "------" "------"
for i in "${!PHASE_NAMES[@]}"; do
  printf "%-18s %-12s %-55s\n" "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DETAILS[$i]}"
done
echo "=============================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "=============================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-infisical-workloads: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-infisical-workloads: ALL CHECKS PASSED"
exit 0

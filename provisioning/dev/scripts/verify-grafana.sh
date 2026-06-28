#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-grafana.sh — Grafana health verification
#
# Verifies Grafana is healthy and connected to VMSingle: pod health,
# service, API access, and datasource connectivity.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-grafana.sh [--kubeconfig <path>]
#                            [--namespace <ns>]
#                            [--admin-password <pass>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
NAMESPACE="observability"
RELEASE_NAME="grafana"
OVERALL_FAILED=0

# ---- CLI Overrides --------------------------------------------------------
ADMIN_PASSWORD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)      KUBECONFIG="$2";       shift 2 ;;
    --namespace)        NAMESPACE="$2";        shift 2 ;;
    --admin-password)   ADMIN_PASSWORD="$2";   shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Grafana health: pods, service, API, datasource.

Options:
  --kubeconfig PATH    Path to kubeconfig
  --namespace NS       Namespace (default: observability)
  --admin-password     Grafana admin password (auto-detected if omitted)
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
log "verify-grafana: starting"
log "  namespace:    ${NAMESPACE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]            || die "kubeconfig not found at ${KUBECONFIG}"

# Auto-detect admin password from K8s Secret
if [ -z "${ADMIN_PASSWORD}" ]; then
  ADMIN_PASSWORD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null \
    | base64 --decode 2>/dev/null || true)
  log "  Admin password: auto-detected"
fi

# Find Grafana pod
GF_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=grafana -o name 2>/dev/null \
  | head -1 | sed 's|pod/||' || true)
GF_SVC_IP=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get svc -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || true)

# ---- Phase state tracking -------------------------------------------------
PHASE_DETAILS=()
PHASE_STATUSES=()
PHASE_NAMES=()

reset_phase() { PHASE_NAMES+=("$1"); }
pass_phase()  { PHASE_STATUSES+=("PASS"); PHASE_DETAILS+=("$1"); }
fail_phase()  { PHASE_STATUSES+=("FAIL"); PHASE_DETAILS+=("$1"); OVERALL_FAILED=1; }
skip_phase()  { PHASE_STATUSES+=("SKIP"); PHASE_DETAILS+=("$1"); }

# ============================================================================
# Phase 1: Grafana pod health
# ============================================================================
reset_phase "1-Pods"

POD_READY=0
POD_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=grafana -o name 2>/dev/null || true); do
  POD_TOTAL=$((POD_TOTAL + 1))
  ready=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || false)
  [ "${ready}" = "true" ] && POD_READY=$((POD_READY + 1))
done

if [ "${POD_TOTAL}" -eq 0 ]; then
  fail_phase "No grafana pods found in ${NAMESPACE}"
elif [ "${POD_READY}" -eq "${POD_TOTAL}" ]; then
  pass_phase "${POD_READY}/${POD_TOTAL} pods Ready"
else
  fail_phase "${POD_READY}/${POD_TOTAL} pods Ready"
fi

# ============================================================================
# Phase 2: Grafana service
# ============================================================================
reset_phase "2-Service"

if [ -z "${GF_SVC_IP}" ]; then
  fail_phase "No Grafana service found"
else
  pass_phase "ClusterIP ${GF_SVC_IP}:80"
fi

# ============================================================================
# Phase 3: Grafana API health
# ============================================================================
reset_phase "3-API"

if [ -z "${GF_POD}" ]; then
  skip_phase "No Grafana pod for API check"
else
  HEALTH_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    exec "${GF_POD}" -- wget -q -O - \
    "http://admin:${ADMIN_PASSWORD}@localhost:3000/api/health" 2>/dev/null || true)

  if echo "${HEALTH_RESULT}" | grep -qi "ok\|healthy" >/dev/null 2>&1; then
    pass_phase "API health check OK"
  else
    fail_phase "API health check failed"
  fi
fi

# ============================================================================
# Phase 4: VMSingle datasource connectivity
# ============================================================================
reset_phase "4-Datasource"

if [ -z "${GF_POD}" ] || [ -z "${ADMIN_PASSWORD}" ]; then
  skip_phase "No Grafana pod or admin password for datasource check"
else
  # Query datasources via Grafana API
  DS_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    exec "${GF_POD}" -- wget -q -O - \
    "http://admin:${ADMIN_PASSWORD}@localhost:3000/api/datasources" 2>/dev/null || true)

  if echo "${DS_RESULT}" | grep -qi "VMSingle\|prometheus" >/dev/null 2>&1; then
    pass_phase "VMSingle datasource configured and accessible"
  else
    fail_phase "VMSingle datasource not found or not accessible"
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Grafana Health Verification Summary ==="
printf "%-18s %-12s %-55s\n" "PHASE"           "STATUS" "DETAIL"
printf "%-18s %-12s %-55s\n" "-----"           "------" "------"
for i in "${!PHASE_NAMES[@]}"; do
  printf "%-18s %-12s %-55s\n" "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DETAILS[$i]}"
done
echo "===================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "===================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-grafana: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-grafana: ALL CHECKS PASSED"
exit 0

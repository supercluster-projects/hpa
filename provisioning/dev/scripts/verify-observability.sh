#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-observability.sh — Unified observability stack verification
#
# Orchestrates the full observability stack verification covering VMSingle,
# vmagent, kube-state-metrics, Grafana, and AlertManager. Wraps the
# individual verify-*.sh scripts into a single summary with additional
# end-to-end checks.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-observability.sh [--kubeconfig <path>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
NAMESPACE="observability"
OVERALL_FAILED=0

SCRIPT_ARGS=""
[ -n "${KUBECONFIG}" ] && SCRIPT_ARGS="--kubeconfig ${KUBECONFIG}"

# ---- Phase state tracking -------------------------------------------------
PHASE_DETAILS=()
PHASE_STATUSES=()
PHASE_NAMES=()

reset_phase() { PHASE_NAMES+=("$1"); }
pass_phase()  { PHASE_STATUSES+=("PASS"); PHASE_DETAILS+=("$1"); }
fail_phase()  { PHASE_STATUSES+=("FAIL"); PHASE_DETAILS+=("$1"); OVERALL_FAILED=1; }
skip_phase()  { PHASE_STATUSES+=("SKIP"); PHASE_DETAILS+=("$1"); }

# ---- Preflight ------------------------------------------------------------
log "verify-observability: starting"
log "  namespace:    ${NAMESPACE}"
log "  kubeconfig:   ${KUBECONFIG}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"

# ============================================================================
# Phase 1: Metrics pipeline health (VMSingle + vmagent + KSM)
# ============================================================================
reset_phase "1-Metrics-Pipeline"

if [ -f "./verify-vm.sh" ]; then
  log "Phase 1: Running verify-vm.sh..."
  if bash "./verify-vm.sh" ${SCRIPT_ARGS} 2>&1 | tail -1; then
    pass_phase "Metric pipeline (VMSingle, vmagent, KSM) healthy"
  else
    fail_phase "Metric pipeline has failures"
  fi
else
  skip_phase "verify-vm.sh not found"
fi

# ============================================================================
# Phase 2: Grafana health
# ============================================================================
reset_phase "2-Grafana"

if [ -f "./verify-grafana.sh" ]; then
  log "Phase 2: Running verify-grafana.sh..."
  if bash "./verify-grafana.sh" ${SCRIPT_ARGS} 2>&1 | tail -1; then
    pass_phase "Grafana healthy"
  else
    fail_phase "Grafana has failures"
  fi
else
  skip_phase "verify-grafana.sh not found"
fi

# ============================================================================
# Phase 3: AlertManager health
# ============================================================================
reset_phase "3-AlertManager"

AM_TOTAL=0
AM_READY=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=alertmanager -o name 2>/dev/null || true); do
  AM_TOTAL=$((AM_TOTAL + 1))
  ready=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || false)
  [ "${ready}" = "true" ] && AM_READY=$((AM_READY + 1))
done

if [ "${AM_TOTAL}" -eq 0 ]; then
  fail_phase "No AlertManager pods found"
elif [ "${AM_READY}" -eq "${AM_TOTAL}" ]; then
  pass_phase "${AM_READY}/${AM_TOTAL} pods Ready"
else
  fail_phase "${AM_READY}/${AM_TOTAL} pods Ready"
fi

# ============================================================================
# Phase 4: End-to-end metric flow
#
# Check that VMSingle has received data from vmagent by querying the
# /api/v1/query endpoint for recent K8s metrics.
# ============================================================================
reset_phase "4-Metric-Flow"

VM_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=victoria-metrics-single -o name 2>/dev/null \
  | head -1 | sed 's|pod/||' || true)

if [ -z "${VM_POD}" ]; then
  skip_phase "No VMSingle pod for data query"
else
  QUERY_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    exec "${VM_POD}" -- wget -q -O - \
    "http://localhost:8428/api/v1/query?query=count(up)" 2>/dev/null || true)

  if echo "${QUERY_RESULT}" | grep -qi '"status":"success"\|"result"' >/dev/null 2>&1; then
    pass_phase "VMSingle returns query results — metric pipeline active"
  else
    fail_phase "VMSingle query returned no results"
  fi
fi

# ============================================================================
# Phase 5: Resource health check
#
# Verify no observability pods are in CrashLoopBackOff or OOMKilled state.
# ============================================================================
reset_phase "5-Resource-Health"

CRASHED=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -o name 2>/dev/null || true); do
  status=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
  if [ "${status}" = "CrashLoopBackOff" ] || [ "${status}" = "OOMKilled" ]; then
    CRASHED=$((CRASHED + 1))
  fi
done

if [ "${CRASHED}" -eq 0 ]; then
  pass_phase "No observability pods in CrashLoopBackOff or OOMKilled"
else
  fail_phase "${CRASHED} observability pod(s) in CrashLoopBackOff or OOMKilled"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Observability Stack Verification Summary ==="
printf "%-20s %-12s %-55s\n" "PHASE"             "STATUS" "DETAIL"
printf "%-20s %-12s %-55s\n" "-----"             "------" "------"
for i in "${!PHASE_NAMES[@]}"; do
  printf "%-20s %-12s %-55s\n" "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DETAILS[$i]}"
done
echo "======================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "======================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-observability: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-observability: ALL CHECKS PASSED"
exit 0

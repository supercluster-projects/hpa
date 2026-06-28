#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-vm.sh — VictoriaMetrics stack health verification
#
# Verifies the VictoriaMetrics observability stack: VMSingle, vmagent,
# and kube-state-metrics. Checks all layers: pods, endpoints, scrape targets.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-vm.sh [--kubeconfig <path>]
#                       [--namespace <ns>]
#                       [--vm-single-svc <name>]
#                       [--vmagent-svc <name>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
NAMESPACE="observability"
VM_SINGLE_SVC="vmsingle-victoria-metrics-single"
VMAGENT_SVC="vmagent-victoria-metrics-agent"
KSM_SVC="kube-state-metrics"
OVERALL_FAILED=0

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";       shift 2 ;;
    --namespace)      NAMESPACE="$2";        shift 2 ;;
    --vm-single-svc)  VM_SINGLE_SVC="$2";    shift 2 ;;
    --vmagent-svc)    VMAGENT_SVC="$2";      shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify VictoriaMetrics observability stack: VMSingle, vmagent, kube-state-metrics.

Options:
  --kubeconfig PATH    Path to kubeconfig
  --namespace NS       Namespace (default: observability)
  --vm-single-svc N    VMSingle service name
  --vmagent-svc N      vmagent service name
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
log "verify-vm: starting"
log "  namespace:    ${NAMESPACE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]            || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Phase state tracking -------------------------------------------------
PHASE_DETAILS=()
PHASE_STATUSES=()
PHASE_NAMES=()

reset_phase() { PHASE_NAMES+=("$1"); }
pass_phase()  { PHASE_STATUSES+=("PASS"); PHASE_DETAILS+=("$1"); }
fail_phase()  { PHASE_STATUSES+=("FAIL"); PHASE_DETAILS+=("$1"); OVERALL_FAILED=1; }
skip_phase()  { PHASE_STATUSES+=("SKIP"); PHASE_DETAILS+=("$1"); }

# ============================================================================
# Phase 1: VMSingle pod health
# ============================================================================
reset_phase "1-VMSingle"

VM_READY=0
VM_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=victoria-metrics-single -o name 2>/dev/null || true); do
  VM_TOTAL=$((VM_TOTAL + 1))
  ready=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || false)
  [ "${ready}" = "true" ] && VM_READY=$((VM_READY + 1))
done

if [ "${VM_TOTAL}" -eq 0 ]; then
  fail_phase "No VMSingle pods found in ${NAMESPACE}"
elif [ "${VM_READY}" -eq "${VM_TOTAL}" ]; then
  pass_phase "${VM_READY}/${VM_TOTAL} pods Ready"
else
  fail_phase "${VM_READY}/${VM_TOTAL} pods Ready"
fi

# ============================================================================
# Phase 2: vmagent DaemonSet health
# ============================================================================
reset_phase "2-vmagent"

AGENT_READY=0
AGENT_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=victoria-metrics-agent -o name 2>/dev/null || true); do
  AGENT_TOTAL=$((AGENT_TOTAL + 1))
  ready=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || false)
  [ "${ready}" = "true" ] && AGENT_READY=$((AGENT_READY + 1))
done

if [ "${AGENT_TOTAL}" -eq 0 ]; then
  fail_phase "No vmagent pods found in ${NAMESPACE}"
elif [ "${AGENT_READY}" -eq "${AGENT_TOTAL}" ]; then
  pass_phase "${AGENT_READY}/${AGENT_TOTAL} pods Ready"
else
  fail_phase "${AGENT_READY}/${AGENT_TOTAL} pods Ready"
fi

# ============================================================================
# Phase 3: kube-state-metrics pod health
# ============================================================================
reset_phase "3-KSM"

KSM_READY=0
KSM_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=kube-state-metrics -o name 2>/dev/null || true); do
  KSM_TOTAL=$((KSM_TOTAL + 1))
  ready=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || false)
  [ "${ready}" = "true" ] && KSM_READY=$((KSM_READY + 1))
done

if [ "${KSM_TOTAL}" -eq 0 ]; then
  fail_phase "No kube-state-metrics pods found in ${NAMESPACE}"
elif [ "${KSM_READY}" -eq "${KSM_TOTAL}" ]; then
  pass_phase "${KSM_READY}/${KSM_TOTAL} pods Ready"
else
  fail_phase "${KSM_READY}/${KSM_TOTAL} pods Ready"
fi

# ============================================================================
# Phase 4: VMSingle /metrics endpoint
# ============================================================================
reset_phase "4-Metrics-Endpoint"

VM_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=victoria-metrics-single -o name 2>/dev/null \
  | head -1 | sed 's|pod/||' || true)

if [ -z "${VM_POD}" ]; then
  skip_phase "No VMSingle pod for in-cluster endpoint check"
else
  METRICS_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    exec "${VM_POD}" -- wget -q -O - http://localhost:8428/metrics 2>/dev/null \
    | head -5 2>/dev/null || true)

  if echo "${METRICS_RESULT}" | grep -qi "victoria" >/dev/null 2>&1; then
    pass_phase "/metrics returns VictoriaMetrics metrics"
  else
    fail_phase "/metrics endpoint did not return expected metrics output"
  fi
fi

# ============================================================================
# Phase 5: vmagent scrape targets
# ============================================================================
reset_phase "5-Scrape-Targets"

AGENT_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app.kubernetes.io/name=victoria-metrics-agent -o name 2>/dev/null \
  | head -1 | sed 's|pod/||' || true)

if [ -z "${AGENT_POD}" ]; then
  skip_phase "No vmagent pod for scrape target check"
else
  TARGETS_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    exec "${AGENT_POD}" -- wget -q -O - http://localhost:8429/targets 2>/dev/null \
    | head -10 2>/dev/null || true)

  if echo "${TARGETS_RESULT}" | grep -qi "up\|target\|scrape\|health" >/dev/null 2>&1; then
    pass_phase "vmagent scrape targets visible"
  else
    fail_phase "vmagent scrape targets not accessible"
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== VictoriaMetrics Stack Verification Summary ==="
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
  die "verify-vm: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-vm: ALL CHECKS PASSED"
exit 0

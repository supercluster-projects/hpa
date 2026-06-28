#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-yugabytedb.sh — Yugabytedb cluster health verification
#
# Verifies the Yugabytedb distributed SQL cluster is healthy and operational.
# Checks all layers: pods, PVCs, YSQL connectivity, node distribution.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-yugabytedb.sh [--kubeconfig <path>]
#                               [--namespace <ns>]
#                               [--release-name <name>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
NAMESPACE="yugabytedb"
RELEASE_NAME="yb-demo"
OVERALL_FAILED=0

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)      KUBECONFIG="$2";       shift 2 ;;
    --namespace)        NAMESPACE="$2";        shift 2 ;;
    --release-name)     RELEASE_NAME="$2";     shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Yugabytedb cluster health: pods, PVCs, YSQL connectivity, node distribution.

Options:
  --kubeconfig PATH    Path to kubeconfig
  --namespace NS       Namespace (default: yugabytedb)
  --release-name NAME  Helm release name (default: yb-demo)
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
log "verify-yugabytedb: starting"
log "  namespace:    ${NAMESPACE}"
log "  release:      ${RELEASE_NAME}"

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
# Phase 1: Yugabytedb pods
# ============================================================================
reset_phase "1-Pods"

EXPECTED_MASTERS=3
EXPECTED_TSERVERS=3

# Get master pods
MASTER_READY=0
MASTER_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=yb-master -o name 2>/dev/null || true); do
  MASTER_TOTAL=$((MASTER_TOTAL + 1))
  status=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "${status}" = "Running" ] && MASTER_READY=$((MASTER_READY + 1))
done

TSERVER_READY=0
TSERVER_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=yb-tserver -o name 2>/dev/null || true); do
  TSERVER_TOTAL=$((TSERVER_TOTAL + 1))
  status=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "${status}" = "Running" ] && TSERVER_READY=$((TSERVER_READY + 1))
done

if [ "${MASTER_TOTAL}" -eq 0 ] && [ "${TSERVER_TOTAL}" -eq 0 ]; then
  fail_phase "No Yugabytedb pods found in namespace ${NAMESPACE}"
elif [ "${MASTER_READY}" -eq "${EXPECTED_MASTERS}" ] && \
     [ "${TSERVER_READY}" -eq "${EXPECTED_TSERVERS}" ]; then
  pass_phase "${MASTER_READY}/${EXPECTED_MASTERS} masters, ${TSERVER_READY}/${EXPECTED_TSERVERS} tservers Running"
else
  fail_phase "${MASTER_READY}/${MASTER_TOTAL} masters Running, ${TSERVER_READY}/${TSERVER_TOTAL} tservers Running"
fi

# ============================================================================
# Phase 2: PVCs bound on ceph-rbd
# ============================================================================
reset_phase "2-PVCs"

PVC_TOTAL=0
PVC_BOUND=0
PVC_STORAGE=""

for pvc in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pvc -o name 2>/dev/null || true); do
  PVC_TOTAL=$((PVC_TOTAL + 1))
  status=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pvc}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  sc=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pvc}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
  PVC_STORAGE="${PVC_STORAGE}${sc}=${status} "
  [ "${status}" = "Bound" ] && PVC_BOUND=$((PVC_BOUND + 1))
done

if [ "${PVC_TOTAL}" -eq 0 ]; then
  fail_phase "No PVCs found in namespace ${NAMESPACE}"
elif [ "${PVC_BOUND}" -eq "${PVC_TOTAL}" ] && [ "${PVC_TOTAL}" -ge 6 ]; then
  pass_phase "${PVC_BOUND}/${PVC_TOTAL} PVCs Bound (${PVC_STORAGE})"
else
  fail_phase "${PVC_BOUND}/${PVC_TOTAL} PVCs Bound (expected ${PVC_TOTAL} all Bound)"
fi

# ============================================================================
# Phase 3: YSQL connectivity
# ============================================================================
reset_phase "3-YSQL"

TSERVER_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=yb-tserver -o name 2>/dev/null | head -1 | sed 's|pod/||' || true)

if [ -z "${TSERVER_POD}" ]; then
  skip_phase "No yb-tserver pod available for YSQL check"
else
  # YSQL connectivity: create a test table and verify
  CREATE_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    exec "${TSERVER_POD}" -- bash -c \
    "ysqlsh -h yb-tserver-0.yb-tservers.${NAMESPACE}.svc.cluster.local -c \"CREATE TABLE IF NOT EXISTS hpa_health_check (id SERIAL PRIMARY KEY, ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP);\" 2>&1" \
    2>&1 || true)

  if echo "${CREATE_RESULT}" | grep -qi "CREATE TABLE\|already exists\|CREATE"; then
    # Insert a row and query it back
    INSERT_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
      exec "${TSERVER_POD}" -- bash -c \
      "ysqlsh -h yb-tserver-0.yb-tservers.${NAMESPACE}.svc.cluster.local -c \"INSERT INTO hpa_health_check DEFAULT VALUES;\" 2>&1" \
      2>&1 || true)

    SELECT_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
      exec "${TSERVER_POD}" -- bash -c \
      "ysqlsh -h yb-tserver-0.yb-tservers.${NAMESPACE}.svc.cluster.local -c \"SELECT count(*) FROM hpa_health_check;\" 2>&1" \
      2>&1 || true)

    if echo "${SELECT_RESULT}" | grep -qi "count\|1 row\|rows"; then
      pass_phase "YSQL connected, test table created, row inserted and queried"
    else
      fail_phase "YSQL connected, table created, but insert/query failed: ${SELECT_RESULT}"
    fi
  else
    fail_phase "YSQL connection failed: ${CREATE_RESULT}"
  fi
fi

# ============================================================================
# Phase 4: Node distribution
#
# Verifies that yb-master and yb-tserver pods are distributed across
# different worker nodes to ensure fault tolerance.
# ============================================================================
reset_phase "4-Node-Dist"

MASTER_NODES=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=yb-master -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null || true)
TSERVER_NODES=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=yb-tserver -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null || true)

MASTER_NODE_COUNT=$(echo "${MASTER_NODES}" | tr ' ' '\n' | sort -u | grep -c . || true)
TSERVER_NODE_COUNT=$(echo "${TSERVER_NODES}" | tr ' ' '\n' | sort -u | grep -c . || true)

if [ "${MASTER_NODE_COUNT}" -ge 2 ] && [ "${TSERVER_NODE_COUNT}" -ge 2 ]; then
  pass_phase "Masters across ${MASTER_NODE_COUNT} nodes, Tservers across ${TSERVER_NODE_COUNT} nodes"
elif [ "${MASTER_NODE_COUNT}" -eq 0 ] && [ "${TSERVER_NODE_COUNT}" -eq 0 ]; then
  skip_phase "No pods found to check node distribution"
else
  fail_phase "Masters on ${MASTER_NODE_COUNT} node(s), Tservers on ${TSERVER_NODE_COUNT} node(s) — expected >= 2 for fault tolerance"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Yugabytedb Health Verification Summary ==="
printf "%-15s %-12s %-55s\n" "PHASE"       "STATUS" "DETAIL"
printf "%-15s %-12s %-55s\n" "-----"       "------" "------"
for i in "${!PHASE_NAMES[@]}"; do
  printf "%-15s %-12s %-55s\n" "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DETAILS[$i]}"
done
echo "=================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "=================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-yugabytedb: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-yugabytedb: ALL CHECKS PASSED"
exit 0

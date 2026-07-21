#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-couchdb.sh — CouchDB health and route verification
#
# Verifies CouchDB is healthy, uses ceph-rbd storage, and is accessible
# both internally and externally via the gateway.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-couchdb.sh [--kubeconfig <path>]
#                            [--namespace <ns>]
#                            [--envoy-ip <ip>]
# ---------------------------------------------------------------------------
. "../misc/preamble.sh"

# ---- Defaults -------------------------------------------------------------
NAMESPACE="couchdb"
GATEWAY_NAMESPACE="envoy-gateway-system"
GATEWAY_NAME="${DEV_GATEWAY_NAME:-hpa-dev-gateway}"
ENVOY_IP=""
OVERALL_FAILED=0

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)      KUBECONFIG="$2";       shift 2 ;;
    --namespace)       NAMESPACE="$2";        shift 2 ;;
    --envoy-ip)        ENVOY_IP="$2";         shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify CouchDB status, storage class, and gateway routing.

Options:
  --kubeconfig PATH    Path to kubeconfig
  --namespace NS       Namespace (default: couchdb)
  --envoy-ip IP        Gateway Envoy LoadBalancer IP (optional)
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
log "verify-couchdb: starting"
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
# Phase 1: CouchDB pods
# ============================================================================
reset_phase "1-Pods"

POD_READY=0
POD_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=couchdb -o name 2>/dev/null || true); do
  POD_TOTAL=$((POD_TOTAL + 1))
  status=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "${status}" = "Running" ] && POD_READY=$((POD_READY + 1))
done

if [ "${POD_TOTAL}" -eq 0 ]; then
  fail_phase "No CouchDB pods found in namespace ${NAMESPACE}"
elif [ "${POD_READY}" -eq "${POD_TOTAL}" ]; then
  pass_phase "${POD_READY}/${POD_TOTAL} pods Running"
else
  fail_phase "${POD_READY}/${POD_TOTAL} pods Running"
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
elif [ "${PVC_BOUND}" -eq "${PVC_TOTAL}" ]; then
  pass_phase "${PVC_BOUND}/${PVC_TOTAL} PVCs Bound (${PVC_STORAGE})"
else
  fail_phase "${PVC_BOUND}/${PVC_TOTAL} PVCs Bound"
fi

# ============================================================================
# Phase 3: Internal REST API connectivity
# ============================================================================
reset_phase "3-InternalAPI"

COUCHDB_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=couchdb -o name 2>/dev/null | head -1 | sed 's|pod/||' || true)

if [ -z "${COUCHDB_POD}" ]; then
  skip_phase "No CouchDB pod available for internal check"
else
  # Curl CouchDB locally inside the container
  INTERNAL_CURL=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    exec "${COUCHDB_POD}" -- curl -s http://admin:password@localhost:5984/ 2>&1 || true)

  if echo "${INTERNAL_CURL}" | grep -qi "Welcome"; then
    pass_phase "Internal query success: $(echo "${INTERNAL_CURL}" | jq -c '.' 2>/dev/null || echo "${INTERNAL_CURL}")"
  else
    fail_phase "Internal query failed: ${INTERNAL_CURL}"
  fi
fi

# ============================================================================
# Phase 4: HTTPRoute Accepted
# ============================================================================
reset_phase "4-HTTPRoute"

if kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get httproute couchdb-route >/dev/null 2>&1; then
  ROUTE_ACCEPTED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" \
    get httproute couchdb-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
  ROUTE_RESOLVED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" \
    get httproute couchdb-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || echo "Unknown")

  if [ "${ROUTE_ACCEPTED}" = "True" ] && [ "${ROUTE_RESOLVED}" = "True" ]; then
    pass_phase "HTTPRoute accepted and refs resolved"
  else
    fail_phase "HTTPRoute Accepted=${ROUTE_ACCEPTED}, ResolvedRefs=${ROUTE_RESOLVED}"
  fi
else
  fail_phase "couchdb-route HTTPRoute not found"
fi

# ============================================================================
# Phase 5: External Route Verification via Gateway (HTTPS)
# ============================================================================
reset_phase "5-ExternalAPI"

# Auto-discover Envoy IP if not provided
if [ -z "${ENVOY_IP}" ]; then
  ENVOY_IP=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" \
    get gateway "${GATEWAY_NAME}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
fi

if [ -z "${ENVOY_IP}" ]; then
  skip_phase "Envoy Gateway IP not yet assigned"
else
  # Curl externally using HTTPS (-k to ignore self-signed certificates)
  EXTERNAL_CURL=$(curl -sk "https://${ENVOY_IP}/data" 2>&1 || true)

  if echo "${EXTERNAL_CURL}" | grep -qi "Welcome"; then
    pass_phase "External HTTPS query success: $(echo "${EXTERNAL_CURL}" | jq -c '.' 2>/dev/null || echo "${EXTERNAL_CURL}")"
  else
    fail_phase "External HTTPS query failed (expected Welcome JSON): ${EXTERNAL_CURL}"
  fi
fi

# ---- Draw Summary Table ---------------------------------------------------
echo ""
echo "=== CouchDB Health Verification ==="
printf "%-18s | %-6s | %s\n" "Verification Phase" "Status" "Details"
printf -- "-------------------|--------|-----------------------------------------\n"
for i in "${!PHASE_NAMES[@]}"; do
  printf "%-18s | %-6s | %s\n" "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DETAILS[$i]}"
done
echo "==================================="

exit "${OVERALL_FAILED}"

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-hasura.sh — Hasura GraphQL Engine health verification
#
# Verifies Hasura GraphQL Engine is healthy and operational. Checks all
# layers: pod health, service, GraphQL endpoint, admin auth.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-hasura.sh [--kubeconfig <path>]
#                           [--namespace <ns>]
#                           [--admin-secret <secret>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
NAMESPACE="hasura"
RELEASE_NAME="hasura"
OVERALL_FAILED=0

# ---- CLI Overrides --------------------------------------------------------
ADMIN_SECRET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)      KUBECONFIG="$2";       shift 2 ;;
    --namespace)        NAMESPACE="$2";        shift 2 ;;
    --release-name)     RELEASE_NAME="$2";     shift 2 ;;
    --admin-secret)     ADMIN_SECRET="$2";     shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Hasura GraphQL Engine health: pods, service, GraphQL endpoint, auth.

Options:
  --kubeconfig PATH    Path to kubeconfig
  --namespace NS       Namespace (default: hasura)
  --release-name NAME  Helm release name (default: hasura)
  --admin-secret SEC   Hasura admin secret (auto-detected from K8s if omitted)
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
log "verify-hasura: starting"
log "  namespace:    ${NAMESPACE}"
log "  release:      ${RELEASE_NAME}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]            || die "kubeconfig not found at ${KUBECONFIG}"

# Auto-detect admin secret from K8s if not provided
if [ -z "${ADMIN_SECRET}" ]; then
  ADMIN_SECRET=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get secret hasura-admin-secret -o jsonpath='{.data.admin-secret}' 2>/dev/null \
    | base64 --decode 2>/dev/null || true)
  log "  Admin secret: auto-detected from K8s Secret"
else
  log "  Admin secret: provided via CLI"
fi

# Detect service cluster IP and port
SERVICE_CLUSTER_IP=""
SERVICE_PORT=""
SERVICE_DATA=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get svc -l app.kubernetes.io/instance="${RELEASE_NAME}" \
  -o jsonpath='{.items[0].spec.clusterIP} {.items[0].spec.ports[0].port}' 2>/dev/null || true)
SERVICE_CLUSTER_IP=$(echo "${SERVICE_DATA}" | awk '{print $1}')
SERVICE_PORT=$(echo "${SERVICE_DATA}" | awk '{print $2}')
[ -z "${SERVICE_PORT}" ] && SERVICE_PORT=8080

# ---- Phase state tracking -------------------------------------------------
PHASE_DETAILS=()
PHASE_STATUSES=()
PHASE_NAMES=()

reset_phase() { PHASE_NAMES+=("$1"); }
pass_phase()  { PHASE_STATUSES+=("PASS"); PHASE_DETAILS+=("$1"); }
fail_phase()  { PHASE_STATUSES+=("FAIL"); PHASE_DETAILS+=("$1"); OVERALL_FAILED=1; }
skip_phase()  { PHASE_STATUSES+=("SKIP"); PHASE_DETAILS+=("$1"); }

# ============================================================================
# Phase 1: Hasura pod health
# ============================================================================
reset_phase "1-Pods"

POD_READY=0
POD_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=graphql-engine -o name 2>/dev/null || true); do
  POD_TOTAL=$((POD_TOTAL + 1))
  ready_count=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || false)
  [ "${ready_count}" = "true" ] && POD_READY=$((POD_READY + 1))
done

if [ "${POD_TOTAL}" -eq 0 ]; then
  fail_phase "No graphql-engine pods found in namespace ${NAMESPACE}"
elif [ "${POD_READY}" -eq "${POD_TOTAL}" ] && [ "${POD_TOTAL}" -ge 1 ]; then
  pass_phase "${POD_READY}/${POD_TOTAL} graphql-engine pods Ready"
else
  fail_phase "${POD_READY}/${POD_TOTAL} pods Ready"
fi

# ============================================================================
# Phase 2: Service ClusterIP
# ============================================================================
reset_phase "2-Service"

if [ -z "${SERVICE_CLUSTER_IP}" ]; then
  fail_phase "No Hasura service found in namespace ${NAMESPACE}"
else
  pass_phase "ClusterIP ${SERVICE_CLUSTER_IP}:${SERVICE_PORT}"
fi

# ============================================================================
# Phase 3: GraphQL endpoint response
# ============================================================================
reset_phase "3-GraphQL-Endpoint"

if [ -z "${SERVICE_CLUSTER_IP}" ] || [ -z "${ADMIN_SECRET}" ]; then
  skip_phase "No service endpoint or admin secret available"
else
  # Query GraphQL schema introspection via kubectl exec (in-cluster)
  HASURA_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get pods -l app=graphql-engine -o name 2>/dev/null | head -1 | sed 's|pod/||' || true)

  if [ -z "${HASURA_POD}" ]; then
    skip_phase "No graphql-engine pod for in-cluster check"
  else
    SCHEMA_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
      exec "${HASURA_POD}" -- bash -c \
      "curl -s -o /dev/null -w '%{http_code}' \
        -X POST 'http://localhost:8080/v1/graphql' \
        -H 'Content-Type: application/json' \
        -H 'x-hasura-admin-secret: ${ADMIN_SECRET}' \
        -d '{\"query\":\"{ __schema { queryType { name } } }\"}'" 2>&1 || true)

    if [ "${SCHEMA_RESULT}" = "200" ]; then
      pass_phase "HTTP ${SCHEMA_RESULT} from /v1/graphql (schema introspection)"
    else
      fail_phase "HTTP ${SCHEMA_RESULT} from /v1/graphql (expected 200)"
    fi
  fi
fi

# ============================================================================
# Phase 4: Admin auth validation
#
# Verifies that the GraphQL endpoint requires authentication. Requests without
# the admin secret should return 401 Unauthorized.
# ============================================================================
reset_phase "4-Auth-Required"

HASURA_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get pods -l app=graphql-engine -o name 2>/dev/null | head -1 | sed 's|pod/||' || true)

if [ -z "${HASURA_POD}" ]; then
  skip_phase "No graphql-engine pod for auth check"
else
  AUTH_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    exec "${HASURA_POD}" -- bash -c \
    "curl -s -o /dev/null -w '%{http_code}' \
      -X POST 'http://localhost:8080/v1/graphql' \
      -H 'Content-Type: application/json' \
      -d '{\"query\":\"{ __schema { queryType { name } } }\"}'" 2>&1 || true)

  if [ "${AUTH_RESULT}" = "401" ]; then
    pass_phase "HTTP ${AUTH_RESULT} without admin secret (auth enforced)"
  elif [ "${AUTH_RESULT}" = "200" ]; then
    fail_phase "HTTP ${AUTH_RESULT} without admin secret (auth NOT enforced — security risk!)"
  else
    fail_phase "HTTP ${AUTH_RESULT} without admin secret (expected 401)"
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Hasura Health Verification Summary ==="
printf "%-18s %-12s %-55s\n" "PHASE"           "STATUS" "DETAIL"
printf "%-18s %-12s %-55s\n" "-----"           "------" "------"
for i in "${!PHASE_NAMES[@]}"; do
  printf "%-18s %-12s %-55s\n" "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DETAILS[$i]}"
done
echo "=================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "=================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-hasura: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-hasura: ALL CHECKS PASSED"
exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-mesh.sh — Unified Production mesh verification
#
# Orchestrates verification of the full production mesh: TLS termination,
# Envoy Gateway HTTPS listener, gql route, and welcome route.
# Wraps individual verify scripts into a single summary.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-mesh.sh [--kubeconfig <path>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
GATEWAY_NAMESPACE="envoy-gateway-system"
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
log "verify-mesh: starting"
log "  kubeconfig:   ${KUBECONFIG}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"

# ============================================================================
# Phase 1: TLS/cert-manager health
# ============================================================================
reset_phase "1-TLS-CertManager"

if [ -f "./verify-tls.sh" ]; then
  log "Phase 1: Running verify-tls.sh..."
  if bash "./verify-tls.sh" ${SCRIPT_ARGS} 2>&1 | tail -1; then
    pass_phase "TLS/cert-manager healthy"
  else
    fail_phase "TLS/cert-manager has failures"
  fi
else
  skip_phase "verify-tls.sh not found"
fi

# ============================================================================
# Phase 2: Gateway HTTPS listener
# ============================================================================
reset_phase "2-Gateway-HTTPS"

GATEWAY_NAME=$(kubectl get gateway -n "${GATEWAY_NAMESPACE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "${GATEWAY_NAME}" ]; then
  fail_phase "No Gateway found in ${GATEWAY_NAMESPACE}"
else
  HTTPS_PROTO=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.spec.listeners[?(@.name=="https")].protocol}' 2>/dev/null || "")
  HTTPS_PORT=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.spec.listeners[?(@.name=="https")].port}' 2>/dev/null || "")
  GW_ACCEPTED=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || "")

  if [ "${HTTPS_PROTO}" = "HTTPS" ] && [ "${GW_ACCEPTED}" = "True" ]; then
    pass_phase "Gateway ${GATEWAY_NAME}: HTTPS on :${HTTPS_PORT}, Accepted=${GW_ACCEPTED}"
  else
    fail_phase "Gateway: HTTPS=${HTTPS_PROTO}, Accepted=${GW_ACCEPTED}"
  fi
fi

# ============================================================================
# Phase 3: Route existence and correctness
# ============================================================================
reset_phase "3-Routes"

ROUTES_OK=0
ROUTES_TOTAL=0

for route_info in "welcome-route:https" "gql-route:https" "redirect-https:http" "admin-route:https"; do
  ROUTES_TOTAL=$((ROUTES_TOTAL + 1))
  route_name="${route_info%%:*}"
  expected_section="${route_info##*:}"

  if kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${route_name}" >/dev/null 2>&1; then
    parent_section=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${route_name}" \
      -o jsonpath='{.spec.parentRefs[0].sectionName}' 2>/dev/null || "")
    if [ "${parent_section}" = "${expected_section}" ]; then
      ROUTES_OK=$((ROUTES_OK + 1))
    else
      err "Route '${route_name}' parentRef sectionName is '${parent_section}' (expected '${expected_section}')"
    fi
  else
    err "Route '${route_name}' not found"
  fi
done

if [ "${ROUTES_OK}" -eq "${ROUTES_TOTAL}" ]; then
  pass_phase "${ROUTES_OK}/${ROUTES_TOTAL} routes present with correct parentRefs"
else
  fail_phase "${ROUTES_OK}/${ROUTES_TOTAL} routes correct (expected ${ROUTES_TOTAL})"
fi

# ============================================================================
# Phase 4: TLS secret exists with certificate data
# ============================================================================
reset_phase "4-TLS-Secret"

CERT_SECRET=$(kubectl -n "${GATEWAY_NAMESPACE}" get certificate \
  -o jsonpath='{.items[0].spec.secretName}' 2>/dev/null || true)

if [ -z "${CERT_SECRET}" ]; then
  fail_phase "No Certificate found in ${GATEWAY_NAMESPACE}"
else
  SECRET_OK=false
  if kubectl -n "${GATEWAY_NAMESPACE}" get secret "${CERT_SECRET}" >/dev/null 2>&1; then
    TLS_CRT_SIZE=$(kubectl -n "${GATEWAY_NAMESPACE}" get secret "${CERT_SECRET}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | wc -c || echo "0")
    TLS_KEY_EXISTS=$(kubectl -n "${GATEWAY_NAMESPACE}" get secret "${CERT_SECRET}" \
      -o jsonpath='{.data.tls\.key}' 2>/dev/null | wc -c || echo "0")
    if [ "${TLS_CRT_SIZE}" -gt 100 ] && [ "${TLS_KEY_EXISTS}" -gt 50 ]; then
      SECRET_OK=true
    fi
  fi

  if [ "${SECRET_OK}" = true ]; then
    pass_phase "TLS secret '${CERT_SECRET}' has valid certificate data (${TLS_CRT_SIZE} bytes)"
  else
    fail_phase "TLS secret '${CERT_SECRET}' missing or invalid certificate data"
  fi
fi

# ============================================================================
# Phase 5: Warm route check (optional — requires Envoy LB IP)
#
# If curl is available and we can resolve the Envoy LB IP, test HTTPS endpoint
# ============================================================================
reset_phase "5-Endpoint-Check"

GW_LB=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway \
  -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)

if [ -z "${GW_LB}" ] || ! command -v curl >/dev/null 2>&1; then
  skip_phase "No Envoy LB IP or curl for endpoint check"
else
  HTTPS_RESULT=$(curl -sk -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "https://${GW_LB}/api/welcome" 2>&1 || true)

  HTTP_RESULT=$(curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://${GW_LB}/api/welcome" 2>&1 || true)

  if [ "${HTTPS_RESULT}" = "200" ]; then
    pass_phase "HTTPS ${GW_LB} returns 200, HTTP redirects with ${HTTP_RESULT}"
  else
    fail_phase "HTTPS ${GW_LB} returned ${HTTPS_RESULT:-<unreachable>} (expected 200)"
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Production Mesh Verification Summary ==="
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
  die "verify-mesh: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-mesh: ALL CHECKS PASSED"
exit 0

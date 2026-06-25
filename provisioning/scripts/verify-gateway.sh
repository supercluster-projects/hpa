#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-gateway.sh — Envoy Gateway + Headlamp + route verification
#
# Verifies the ingress gateway stack that workloads depend on:
#   Phase 1: Envoy Gateway pod health (namespace envoy-gateway-system)
#   Phase 2: GatewayClass availability (envoy-gateway GatewayClass exists)
#   Phase 3: Gateway status (hpa-dev-gateway has Accepted=True, Programmed=True,
#            and at least one listener)
#   Phase 4: Headlamp pod health (namespace headlamp)
#   Phase 5: HTTPRoute existence and correctness (welcome-route with
#            /api/welcome prefix, admin-route with /admin prefix, both
#            referencing the correct Gateway)
#   Phase 6: Envoy Gateway LoadBalancer service IP assignment
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-gateway.sh [--kubeconfig <path>]
#           [--gateway-name <name>] [--gateway-namespace <ns>]
#           [--expected-envoy-pods <count>]
#           [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env DEV_GATEWAY_NAME

# ---- Internal defaults (script-internal only) -------------------------
GATEWAY_NAME="${DEV_GATEWAY_NAME}"
GATEWAY_NAMESPACE="envoy-gateway-system"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)             KUBECONFIG="$2";                 shift 2 ;;
    --gateway-name)           GATEWAY_NAME="$2";              shift 2 ;;
    --gateway-namespace)      GATEWAY_NAMESPACE="$2";         shift 2 ;;
    --expected-envoy-pods)    EXPECTED_ENVOY_PODS="$2";       shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Envoy Gateway + Headlamp + HTTPRoute health.

Phases:
  1  Envoy Gateway pod health (namespace: envoy-gateway-system)
  2  GatewayClass availability (envoy-gateway GatewayClass)
  3  Gateway status (conditions: Accepted=True, Programmed=True)
  4  Headlamp pod health (namespace: headlamp)
  5  HTTPRoute existence and correctness (welcome-route, admin-route)
  6  Envoy Gateway LoadBalancer service IP assignment

Options:
  --kubeconfig PATH             Path to kubeconfig (default: ../dev/kubeconfig)
  --gateway-name NAME           Gateway resource name (default: hpa-dev-gateway)
  --gateway-namespace NS        Gateway namespace (default: envoy-gateway-system)
  --expected-envoy-pods COUNT   Expected Envoy Gateway pod count (default: 2)
  --help, -h                    Show this help message

Examples:
  ./verify-gateway.sh --kubeconfig /custom/path/kubeconfig
  ./verify-gateway.sh --gateway-name my-gateway --gateway-namespace my-ns
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-gateway: starting"
log "  kubeconfig:        ${KUBECONFIG}"
log "  gateway name:      ${GATEWAY_NAME}"
log "  gateway namespace: ${GATEWAY_NAMESPACE}"
log "  expected envoy:    ${EXPECTED_ENVOY_PODS} pods"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # Envoy Gateway pods
PHASE1_DETAIL=""
PHASE2_STATUS=""   # GatewayClass
PHASE2_DETAIL=""
PHASE3_STATUS=""   # Gateway conditions
PHASE3_DETAIL=""
PHASE4_STATUS=""   # Headlamp pods
PHASE4_DETAIL=""
PHASE5_STATUS=""   # HTTPRoutes
PHASE5_DETAIL=""
PHASE6_STATUS=""   # LoadBalancer IP
PHASE6_DETAIL=""

OVERALL_FAILED=0

# ---- Helper: check pods in a namespace ------------------------------------
# Usage: check_pod_health <namespace> <expected_count> <var_status> <var_detail>
# Sets the status and detail variables via nameref.
check_pod_health() {
  local ns="$1"
  local expected="$2"
  local -n out_status="$3"
  local -n out_detail="$4"

  log "Checking pod health in namespace '${ns}' (expected ${expected})"

  local POD_OUTPUT
  POD_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pods --no-headers 2>&1) \
    || { err "kubectl get pods in '${ns}' failed: ${POD_OUTPUT}"; out_status="FAIL"; out_detail="kubectl error"; return 1; }

  local TOTAL=0
  local READY=0
  local NOT_OK=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    TOTAL=$((TOTAL + 1))
    local READY_FIELD
    local STATUS_FIELD
    READY_FIELD=$(echo "$line" | awk '{print $2}')
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')
    local READY_NUM="${READY_FIELD%%/*}"

    if [ "${READY_NUM}" -gt 0 ] && [ "${STATUS_FIELD}" = "Running" ]; then
      READY=$((READY + 1))
    else
      local POD_NAME
      POD_NAME=$(echo "$line" | awk '{print $1}')
      NOT_OK="${NOT_OK} ${POD_NAME}(${STATUS_FIELD}/${READY_FIELD})"
    fi
  done <<< "${POD_OUTPUT}"

  if [ -n "${NOT_OK}" ]; then
    err "Pods not ready in '${ns}':${NOT_OK}"
    out_status="FAIL"
    out_detail="${READY}/${TOTAL} ready"
    return 1
  elif [ "${TOTAL}" -eq 0 ]; then
    err "No pods found in namespace '${ns}'"
    out_status="FAIL"
    out_detail="0 pods"
    return 1
  elif [ "${READY}" -eq "${expected}" ]; then
    out_status="PASS"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    log "  -> PASSED"
    return 0
  elif [ "${READY}" -ge "$((expected - 1))" ]; then
    out_status="WARN"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    log "  -> WARN (close to expected)"
    return 0
  else
    local pod_count_note=""
    if [ "${TOTAL}" -gt "${expected}" ] && [ "${READY}" -eq "${TOTAL}" ]; then
      pod_count_note=" (more pods than expected)"
    fi
    err "Pod count mismatch in '${ns}': ${READY}/${TOTAL} ready, expected ${expected}"
    out_status="FAIL"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})${pod_count_note}"
    return 1
  fi
}

# ---- Helper: check CRD availability ---------------------------------------
# Usage: check_crd <crd_name_suffix> <friendly_name> <var_status> <var_detail>
check_crd() {
  local suffix="$1"
  local friendly="$2"
  local -n out_status="$3"
  local -n out_detail="$4"

  log "Checking CRD: ${friendly} (${suffix})"

  if kubectl --kubeconfig "${KUBECONFIG}" get crd "${suffix}" > /dev/null 2>&1; then
    out_status="PASS"
    out_detail="CRD '${suffix}' found"
    log "  -> PASSED"
    return 0
  else
    out_status="FAIL"
    out_detail="CRD '${suffix}' not found"
    log "  -> FAILED"
    return 1
  fi
}

# ============================================================================
# Phase 1: Envoy Gateway pod health (namespace: envoy-gateway-system)
# ============================================================================
log "Phase 1: Envoy Gateway pod health"
if check_pod_health "envoy-gateway-system" "${EXPECTED_ENVOY_PODS}" PHASE1_STATUS PHASE1_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: GatewayClass availability (envoy-gateway GatewayClass exists)
# ============================================================================
log "Phase 2: GatewayClass availability"
GATEWAY_CLASS_NAME="envoy-gateway"

if kubectl --kubeconfig "${KUBECONFIG}" get gatewayclass "${GATEWAY_CLASS_NAME}" > /dev/null 2>&1; then
  # Check the GatewayClass has Accepted=True condition
  GC_ACCEPTED=$(kubectl --kubeconfig "${KUBECONFIG}" get gatewayclass "${GATEWAY_CLASS_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>&1 || true)

  if [ "${GC_ACCEPTED}" = "True" ]; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="GatewayClass '${GATEWAY_CLASS_NAME}' exists and Accepted=True"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
  else
    PHASE2_STATUS="WARN"
    PHASE2_DETAIL="GatewayClass '${GATEWAY_CLASS_NAME}' exists but Accepted condition not True (got: ${GC_ACCEPTED:-none})"
    log "Phase 2: ${PHASE2_DETAIL} -- WARN"
  fi
else
  err "GatewayClass '${GATEWAY_CLASS_NAME}' not found"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="GatewayClass '${GATEWAY_CLASS_NAME}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 3: Gateway status (hpa-dev-gateway with Accepted=True, Programmed=True)
# ============================================================================
log "Phase 3: Gateway status"
if kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" > /dev/null 2>&1; then
  # Collect conditions
  GATEWAY_ACCEPTED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>&1 || true)
  GATEWAY_PROGRAMMED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>&1 || true)

  # Count listeners
  LISTENER_COUNT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.spec.listeners[*].name}' 2>&1 | wc -w || echo "0")

  local detail_parts=""
  local condition_ok=true

  if [ "${GATEWAY_ACCEPTED}" = "True" ]; then
    detail_parts="${detail_parts}Accepted=True"
  else
    detail_parts="${detail_parts}Accepted=${GATEWAY_ACCEPTED:-missing}"
    condition_ok=false
  fi

  if [ "${GATEWAY_PROGRAMMED}" = "True" ]; then
    detail_parts="${detail_parts} Programmed=True"
  else
    detail_parts="${detail_parts} Programmed=${GATEWAY_PROGRAMMED:-missing}"
    condition_ok=false
  fi

  if [ "${LISTENER_COUNT}" -gt 0 ]; then
    detail_parts="${detail_parts} listeners=${LISTENER_COUNT}"
    if [ "${condition_ok}" = true ]; then
      PHASE3_STATUS="PASS"
      PHASE3_DETAIL="Gateway '${GATEWAY_NAME}': ${detail_parts}"
      log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
    else
      PHASE3_STATUS="FAIL"
      PHASE3_DETAIL="Gateway '${GATEWAY_NAME}': ${detail_parts}"
      OVERALL_FAILED=1
    fi
  else
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="Gateway '${GATEWAY_NAME}': ${detail_parts}, no listeners found"
    OVERALL_FAILED=1
  fi
else
  err "Gateway '${GATEWAY_NAME}' not found in namespace '${GATEWAY_NAMESPACE}'"
  PHASE3_STATUS="FAIL"
  PHASE3_DETAIL="Gateway '${GATEWAY_NAME}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 4: Headlamp pod health (namespace: headlamp)
# ============================================================================
log "Phase 4: Headlamp pod health"
# Headlamp namespace and expected count
HEADLAMP_NS="headlamp"
HEADLAMP_EXPECTED=1
# Check if namespace exists; if not, skip gracefully
if kubectl --kubeconfig "${KUBECONFIG}" get ns "${HEADLAMP_NS}" > /dev/null 2>&1; then
  if check_pod_health "${HEADLAMP_NS}" "${HEADLAMP_EXPECTED}" PHASE4_STATUS PHASE4_DETAIL; then
    : # already set
  else
    OVERALL_FAILED=1
  fi
else
  PHASE4_STATUS="SKIP"
  PHASE4_DETAIL="Namespace '${HEADLAMP_NS}' not found — Headlamp may not be deployed"
  log "Phase 4: ${PHASE4_DETAIL}"
fi

# ============================================================================
# Phase 5: HTTPRoute existence and correctness
# ============================================================================
log "Phase 5: HTTPRoute existence and correctness"
PHASE5_FAILED=0

# Define routes to check: "name:namespace:expected_prefix"
ROUTES_TO_CHECK=(
  "welcome-route:${GATEWAY_NAMESPACE}:/api/welcome"
  "admin-route:${GATEWAY_NAMESPACE}:/admin"
)

HTTPROUTE_RESULTS=""

for route_entry in "${ROUTES_TO_CHECK[@]}"; do
  route_name="${route_entry%%:*}"
  remainder="${route_entry#*:}"
  route_ns="${remainder%%:*}"
  expected_prefix="${remainder#*:}"

  log "  Checking HTTPRoute '${route_name}' in '${route_ns}'"

  if kubectl --kubeconfig "${KUBECONFIG}" -n "${route_ns}" get httproute "${route_name}" > /dev/null 2>&1; then
    # Route exists — verify it references the correct gateway
    REF_GW=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${route_ns}" get httproute "${route_name}" \
      -o jsonpath='{.spec.parentRefs[0].name}' 2>&1 || true)

    # Check prefix match
    ROUTE_PREFIX=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${route_ns}" get httproute "${route_name}" \
      -o jsonpath='{.spec.rules[0].matches[0].path.value}' 2>&1 || true)

    local route_ok=true
    local route_detail=""

    if [ "${REF_GW}" = "${GATEWAY_NAME}" ]; then
      route_detail="parentRef=${REF_GW}"
    else
      route_detail="parentRef=${REF_GW:-missing} (expected ${GATEWAY_NAME})"
      route_ok=false
    fi

    if [ "${ROUTE_PREFIX}" = "${expected_prefix}" ]; then
      route_detail="${route_detail}, prefix=${ROUTE_PREFIX}"
    else
      route_detail="${route_detail}, prefix=${ROUTE_PREFIX:-missing} (expected ${expected_prefix})"
      route_ok=false
    fi

    if [ "${route_ok}" = true ]; then
      HTTPROUTE_RESULTS="${HTTPROUTE_RESULTS} ${route_name}[PASS]"
      log "    -> PASSED (${route_detail})"
    else
      HTTPROUTE_RESULTS="${HTTPROUTE_RESULTS} ${route_name}[FAIL]"
      PHASE5_FAILED=1
      err "HTTPRoute '${route_name}' validation failed: ${route_detail}"
    fi
  else
    HTTPROUTE_RESULTS="${HTTPROUTE_RESULTS} ${route_name}[FAIL-not-found]"
    PHASE5_FAILED=1
    err "HTTPRoute '${route_name}' not found in namespace '${route_ns}'"
  fi
done

if [ "${PHASE5_FAILED}" -eq 0 ]; then
  PHASE5_STATUS="PASS"
  PHASE5_DETAIL="all routes OK${HTTPROUTE_RESULTS}"
  log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
else
  PHASE5_STATUS="FAIL"
  PHASE5_DETAIL="route issues detected${HTTPROUTE_RESULTS}"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 6: Envoy Gateway LoadBalancer service IP assignment
# ============================================================================
log "Phase 6: Envoy Gateway LoadBalancer service IP"
# The Envoy proxy service is typically named 'envoy-gateway-proxy' or
# 'envoy-{gateway-name}' in the envoy-gateway-system namespace.
LB_SERVICE_CANDIDATES=(
  "envoy-gateway-proxy:envoy-gateway-system"
  "envoy-${GATEWAY_NAME}:${GATEWAY_NAMESPACE}"
)

LB_FOUND=false

for svc_entry in "${LB_SERVICE_CANDIDATES[@]}"; do
  svc_name="${svc_entry%%:*}"
  svc_ns="${svc_entry#*:}"

  if kubectl --kubeconfig "${KUBECONFIG}" -n "${svc_ns}" get svc "${svc_name}" > /dev/null 2>&1; then
    SVC_TYPE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${svc_ns}" get svc "${svc_name}" \
      -o jsonpath='{.spec.type}' 2>&1 || true)

    if [ "${SVC_TYPE}" = "LoadBalancer" ]; then
      # Check for external IP or hostname
      LB_IP=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${svc_ns}" get svc "${svc_name}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>&1 || true)
      LB_HOSTNAME=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${svc_ns}" get svc "${svc_name}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>&1 || true)

      if [ -n "${LB_IP}" ]; then
        PHASE6_STATUS="PASS"
        PHASE6_DETAIL="Service '${svc_name}' in '${svc_ns}' has LoadBalancer IP: ${LB_IP}"
        LB_FOUND=true
        log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
        break
      elif [ -n "${LB_HOSTNAME}" ]; then
        PHASE6_STATUS="PASS"
        PHASE6_DETAIL="Service '${svc_name}' in '${svc_ns}' has LoadBalancer hostname: ${LB_HOSTNAME}"
        LB_FOUND=true
        log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
        break
      else
        # Service exists as LoadBalancer type but no IP/hostname yet
        PENDING_IP=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${svc_ns}" get svc "${svc_name}" \
          -o jsonpath='{.status.loadBalancer.ingress}' 2>&1 || true)
        if [ -z "${PENDING_IP}" ]; then
          PHASE6_STATUS="WARN"
          PHASE6_DETAIL="Service '${svc_name}' is type LoadBalancer but ingress pending"
          LB_FOUND=true
          log "Phase 6: ${PHASE6_DETAIL} -- WARN"
          break
        fi
      fi
    else
      # Not LoadBalancer — could be ClusterIP in non-LB environments
      PHASE6_STATUS="WARN"
      PHASE6_DETAIL="Service '${svc_name}' is type ${SVC_TYPE} (not LoadBalancer)"
      LB_FOUND=true
      log "Phase 6: ${PHASE6_DETAIL} -- WARN"
      break
    fi
  fi
done

if [ "${LB_FOUND}" = false ]; then
  err "No Envoy Gateway LoadBalancer service found (tried: ${LB_SERVICE_CANDIDATES[*]})"
  PHASE6_STATUS="FAIL"
  PHASE6_DETAIL="no LoadBalancer service found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Gateway Health Verification Summary ==="
printf "%-10s %-12s %-60s\n" "PHASE"         "STATUS" "DETAIL"
printf "%-10s %-12s %-60s\n" "-----"         "------" "------"
printf "%-10s %-12s %-60s\n" "1-Envoy"       "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-60s\n" "2-GatewayClass" "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-60s\n" "3-Gateway"     "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-60s\n" "4-Headlamp"    "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-10s %-12s %-60s\n" "5-HTTPRoutes"  "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-10s %-12s %-60s\n" "6-LB-Svc"      "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
echo "================================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "================================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-gateway: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-gateway: ALL CHECKS PASSED"
exit 0

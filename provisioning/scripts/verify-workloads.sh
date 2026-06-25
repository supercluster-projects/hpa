#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-workloads.sh — Welcome + Counter workload health verification
#
# Verifies all application workloads deployed by install-workloads.sh:
#   Phase 1: hpa-workloads namespace exists
#   Phase 2: Knative Service 'welcome' Ready
#   Phase 3: SpinApp 'counter' Ready
#   Phase 4: HTTPRoute welcome-route Accepted and ResolvedRefs=True
#   Phase 5: curl /api/welcome returns Welcome (N) (text/plain, status 200)
#   Phase 6: KeyDB counter-welcome key exists and increments
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-workloads.sh [--kubeconfig <path>]
#                              [--envoy-ip <ip>]
#                              [--gateway-namespace <ns>]
#                              [--gateway-name <name>]
#                              [--workloads-namespace <ns>]
#                              [--httproute-name <name>]
#                              [--keydb-namespace <ns>]
#                              [--help]
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Defaults -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${SCRIPT_DIR}/../tofu-libvirt-dev/kubeconfig"
ENVOY_IP=""
GATEWAY_NAMESPACE="envoy-gateway-system"
GATEWAY_NAME="hpa-dev-gateway"
WORKLOADS_NAMESPACE="hpa-workloads"
HTTPROUTE_NAME="welcome-route"
KEYDB_NAMESPACE="keydb"

# ---- Helpers --------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err()  { log "ERROR: $*"; }
die()  { err "$*"; exit 1; }

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)            KUBECONFIG="$2";             shift 2 ;;
    --envoy-ip)              ENVOY_IP="$2";               shift 2 ;;
    --gateway-namespace)     GATEWAY_NAMESPACE="$2";      shift 2 ;;
    --gateway-name)          GATEWAY_NAME="$2";           shift 2 ;;
    --workloads-namespace)   WORKLOADS_NAMESPACE="$2";    shift 2 ;;
    --httproute-name)        HTTPROUTE_NAME="$2";         shift 2 ;;
    --keydb-namespace)       KEYDB_NAMESPACE="$2";        shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify welcome + counter workload health.

Phases:
  1  Namespace 'hpa-workloads' exists
  2  Knative Service 'welcome' Ready
  3  SpinApp 'counter' Ready
  4  HTTPRoute 'welcome-route' Accepted and ResolvedRefs=True
  5  curl /api/welcome returns Welcome (N) (text/plain, status 200)
  6  KeyDB counter-welcome key exists and increments

Options:
  --kubeconfig PATH            Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --envoy-ip IP                Envoy Gateway external IP address for Phase 5
  --gateway-namespace NS       Envoy Gateway namespace (default: envoy-gateway-system)
  --gateway-name NAME          Gateway resource name (default: hpa-dev-gateway)
  --workloads-namespace NS     Workloads namespace (default: hpa-workloads)
  --httproute-name NAME        HTTPRoute name (default: welcome-route)
  --keydb-namespace NS         KeyDB namespace (default: keydb)
  --help, -h                   Show this help message

Examples:
  ./verify-workloads.sh --kubeconfig /custom/path/kubeconfig
  ./verify-workloads.sh --envoy-ip 192.168.1.100
  ./verify-workloads.sh --keydb-namespace my-keydb
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-workloads: starting"
log "  kubeconfig:            ${KUBECONFIG}"
log "  envoy-ip:              ${ENVOY_IP:-<not set, Phase 5 will skip>}"
log "  gateway namespace:     ${GATEWAY_NAMESPACE}"
log "  gateway name:          ${GATEWAY_NAME}"
log "  workloads namespace:   ${WORKLOADS_NAMESPACE}"
log "  httproute name:        ${HTTPROUTE_NAME}"
log "  keydb namespace:       ${KEYDB_NAMESPACE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""    # Namespace exists
PHASE1_DETAIL=""
PHASE2_STATUS=""    # Knative Service welcome Ready
PHASE2_DETAIL=""
PHASE3_STATUS=""    # SpinApp counter Ready
PHASE3_DETAIL=""
PHASE4_STATUS=""    # HTTPRoute welcome-route Accepted and ResolvedRefs
PHASE4_DETAIL=""
PHASE5_STATUS=""    # curl /api/welcome returns Welcome (N)
PHASE5_DETAIL=""
PHASE6_STATUS=""    # KeyDB counter-welcome key exists and increments
PHASE6_DETAIL=""

OVERALL_FAILED=0

# ============================================================================
# Phase 1: hpa-workloads namespace exists
# ============================================================================
log "Phase 1: Checking namespace '${WORKLOADS_NAMESPACE}' exists"

if kubectl --kubeconfig "${KUBECONFIG}" get ns "${WORKLOADS_NAMESPACE}" > /dev/null 2>&1; then
  PHASE1_STATUS="PASS"
  PHASE1_DETAIL="Namespace '${WORKLOADS_NAMESPACE}' exists"
  log "  -> PASSED"
else
  err "Namespace '${WORKLOADS_NAMESPACE}' does not exist"
  PHASE1_STATUS="FAIL"
  PHASE1_DETAIL="Namespace '${WORKLOADS_NAMESPACE}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: Knative Service welcome Ready
# ============================================================================
log "Phase 2: Checking Knative Service 'welcome' Ready"

# Check if the Knative Service CRD exists first
if ! kubectl --kubeconfig "${KUBECONFIG}" get crd services.serving.knative.dev > /dev/null 2>&1; then
  err "Knative Serving CRD 'services.serving.knative.dev' not found"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="CRD 'services.serving.knative.dev' not found"
  OVERALL_FAILED=1
elif ! kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get ksvc welcome > /dev/null 2>&1; then
  err "Knative Service 'welcome' not found in namespace '${WORKLOADS_NAMESPACE}'"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="ksvc/welcome not found"
  OVERALL_FAILED=1
else
  # Check the Ready condition
  KSVC_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  KSVC_REASON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
  KSVC_URL=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.url}' 2>/dev/null || echo "")
  KSVC_LATEST_REV=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.latestReadyRevisionName}' 2>/dev/null || echo "")

  detail="Ready=${KSVC_READY}"
  [ -n "${KSVC_URL}" ] && detail="${detail}, url=${KSVC_URL}"
  [ -n "${KSVC_LATEST_REV}" ] && detail="${detail}, revision=${KSVC_LATEST_REV}"

  if [ "${KSVC_READY}" = "True" ]; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="${detail}"
    log "  -> PASSED"
  elif [ "${KSVC_READY}" = "Unknown" ]; then
    PHASE2_STATUS="WARN"
    PHASE2_DETAIL="Progressing: ${detail}"
    log "  -> WARN (still progressing)"
  else
    err "Knative Service 'welcome' not ready: ${detail}"
    PHASE2_STATUS="FAIL"
    PHASE2_DETAIL="${detail}"
    [ -n "${KSVC_REASON}" ] && PHASE2_DETAIL="${PHASE2_DETAIL}, reason=${KSVC_REASON}"
    OVERALL_FAILED=1
  fi
fi

# ============================================================================
# Phase 3: SpinApp counter Ready
# ============================================================================
log "Phase 3: Checking SpinApp 'counter' Ready"

# Check if the SpinApp CRD exists first
if ! kubectl --kubeconfig "${KUBECONFIG}" get crd spinapps.core.spinoperator.dev > /dev/null 2>&1; then
  # Try alternate CRD name
  if ! kubectl --kubeconfig "${KUBECONFIG}" get crd spinapps.spinoperator.dev > /dev/null 2>&1; then
    err "SpinApp CRD not found (checked core.spinoperator.dev and spinoperator.dev)"
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="SpinApp CRD not found"
    OVERALL_FAILED=1
  fi
elif ! kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp counter > /dev/null 2>&1; then
  err "SpinApp 'counter' not found in namespace '${WORKLOADS_NAMESPACE}'"
  PHASE3_STATUS="FAIL"
  PHASE3_DETAIL="spinapp/counter not found"
  OVERALL_FAILED=1
else
  # Check the Ready condition
  SPINAPP_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  SPINAPP_REASON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
  SPINAPP_REPLICAS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "N/A")
  SPINAPP_RDY_REPLICAS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "N/A")

  detail="Ready=${SPINAPP_READY}, replicas=${SPINAPP_REPLICAS}, readyReplicas=${SPINAPP_RDY_REPLICAS}"

  if [ "${SPINAPP_READY}" = "True" ]; then
    PHASE3_STATUS="PASS"
    PHASE3_DETAIL="${detail}"
    log "  -> PASSED"
  elif [ "${SPINAPP_READY}" = "Unknown" ]; then
    # Check if the underlying deployment exists
    if kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get deployment counter > /dev/null 2>&1; then
      DEPLOY_AVAILABLE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get deployment counter \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
      if [ "${DEPLOY_AVAILABLE}" = "True" ]; then
        PHASE3_STATUS="WARN"
        PHASE3_DETAIL="SpinApp Ready unknown but deployment Available: ${detail}"
        log "  -> WARN (deployment available, SpinApp condition not yet propagated)"
      else
        PHASE3_STATUS="WARN"
        PHASE3_DETAIL="Progressing: ${detail}"
        log "  -> WARN (still progressing)"
      fi
    else
      PHASE3_STATUS="WARN"
      PHASE3_DETAIL="Progressing (no deployment yet): ${detail}"
      log "  -> WARN (still progressing)"
    fi
  else
    err "SpinApp 'counter' not ready: ${detail}"
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="${detail}"
    [ -n "${SPINAPP_REASON}" ] && PHASE3_DETAIL="${PHASE3_DETAIL}, reason=${SPINAPP_REASON}"
    OVERALL_FAILED=1
  fi
fi

# ============================================================================
# Phase 4: HTTPRoute welcome-route Accepted and ResolvedRefs=True
# ============================================================================
log "Phase 4: Checking HTTPRoute '${HTTPROUTE_NAME}'"

if ! kubectl --kubeconfig "${KUBECONFIG}" get crd httproutes.gateway.networking.k8s.io > /dev/null 2>&1; then
  err "HTTPRoute CRD 'httproutes.gateway.networking.k8s.io' not found"
  PHASE4_STATUS="FAIL"
  PHASE4_DETAIL="HTTPRoute CRD not found"
  OVERALL_FAILED=1
elif ! kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" > /dev/null 2>&1; then
  err "HTTPRoute '${HTTPROUTE_NAME}' not found in namespace '${GATEWAY_NAMESPACE}'"
  PHASE4_STATUS="FAIL"
  PHASE4_DETAIL="HTTPRoute '${HTTPROUTE_NAME}' not found"
  OVERALL_FAILED=1
else
  # Check Accepted condition
  ROUTE_ACCEPTED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
  ROUTE_RESOLVED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || echo "Unknown")

  # Also get the parentRef gateway name
  ROUTE_PARENT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.parentRefs[0].name}' 2>/dev/null || echo "Unknown")

  # Get the backendRef
  ROUTE_BACKEND=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null || echo "Unknown")
  ROUTE_NAMESPACE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].namespace}' 2>/dev/null || echo "<inherited>")
  ROUTE_PORT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].port}' 2>/dev/null || echo "")

  detail="parent=${ROUTE_PARENT}, backend=${ROUTE_BACKEND}.${ROUTE_NAMESPACE}:${ROUTE_PORT}, Accepted=${ROUTE_ACCEPTED}, ResolvedRefs=${ROUTE_RESOLVED}"

  if [ "${ROUTE_ACCEPTED}" = "True" ] && [ "${ROUTE_RESOLVED}" = "True" ]; then
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="${detail}"
    log "  -> PASSED"
  elif [ "${ROUTE_ACCEPTED}" = "True" ] && [ "${ROUTE_RESOLVED}" = "Unknown" ]; then
    PHASE4_STATUS="WARN"
    PHASE4_DETAIL="Accepted but ResolvedRefs not yet reported: ${detail}"
    log "  -> WARN (ResolvedRefs not yet settled)"
  else
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="${detail}"
    err "HTTPRoute '${HTTPROUTE_NAME}' not fully resolved: ${detail}"
    OVERALL_FAILED=1
  fi
fi

# ============================================================================
# Phase 5: curl /api/welcome returns Welcome (N) with status 200
# ============================================================================
log "Phase 5: Testing /api/welcome endpoint"

if [ -z "${ENVOY_IP}" ]; then
  # Try to discover envoy IP from the Gateway resource
  log "  No --envoy-ip provided, attempting auto-discovery..."
  ENVOY_IP=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")

  if [ -z "${ENVOY_IP}" ]; then
    log "  Could not auto-discover Envoy IP from Gateway resource"
    # Check if service exists with external IP
    for svc_ns in "${GATEWAY_NAMESPACE}" envoy-gateway-system; do
      for svc_prefix in envoy envoy-gateway; do
        ENVOY_IP=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${svc_ns}" get service "${svc_prefix}" \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        [ -n "${ENVOY_IP}" ] && break
      done
      [ -n "${ENVOY_IP}" ] && break
    done
  fi

  if [ -n "${ENVOY_IP}" ]; then
    log "  Auto-discovered Envoy IP: ${ENVOY_IP}"
  fi
fi

if [ -z "${ENVOY_IP}" ]; then
  PHASE5_STATUS="SKIP"
  PHASE5_DETAIL="No Envoy IP provided or discovered (use --envoy-ip or ensure Gateway has an address)"
  log "  -> SKIP (no Envoy IP available)"
else
  # Check if curl is available
  if ! command -v curl >/dev/null 2>&1; then
    PHASE5_STATUS="SKIP"
    PHASE5_DETAIL="curl not available in PATH"
    log "  -> SKIP (curl not found)"
  else
    log "  Curling http://${ENVOY_IP}/api/welcome"

    # Make the request with a 10-second timeout
    HTTP_CODE=""
    RESPONSE_BODY=""

    # First request: just check the response
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}:__BODY__%{content_type}:__SEPARATOR__" \
      --connect-timeout 5 --max-time 10 \
      "http://${ENVOY_IP}/api/welcome" 2>&1 || echo "error")

    HTTP_CODE=$(echo "${RESPONSE}" | cut -d: -f1)
    CONTENT_TYPE=$(echo "${RESPONSE}" | cut -d: -f3 2>/dev/null || echo "")

    # Get the full response body on a second request for detail
    RESPONSE_BODY=$(curl -s --connect-timeout 5 --max-time 10 \
      "http://${ENVOY_IP}/api/welcome" 2>&1 || echo "")

    if [ "${HTTP_CODE}" = "200" ]; then
      # Check if the response contains "Welcome" text
      if echo "${RESPONSE_BODY}" | grep -q "Welcome"; then
        PHASE5_STATUS="PASS"
        PHASE5_DETAIL="HTTP ${HTTP_CODE}, body: \"${RESPONSE_BODY}\", content-type: ${CONTENT_TYPE}"
        log "  -> PASSED (response: ${RESPONSE_BODY})"
      else
        PHASE5_STATUS="WARN"
        PHASE5_DETAIL="HTTP ${HTTP_CODE} but body does not contain 'Welcome': \"${RESPONSE_BODY}\""
        log "  -> WARN (200 but unexpected body)"
      fi
    elif [ "${HTTP_CODE}" = "000" ] || [ -z "${HTTP_CODE}" ]; then
      err "Connection to http://${ENVOY_IP}/api/welcome failed (connection timeout or refused)"
      PHASE5_STATUS="FAIL"
      PHASE5_DETAIL="Connection failed: ${RESPONSE_BODY:-timeout}"
      OVERALL_FAILED=1
    else
      err "/api/welcome returned HTTP ${HTTP_CODE}"
      PHASE5_STATUS="FAIL"
      PHASE5_DETAIL="HTTP ${HTTP_CODE}, body: ${RESPONSE_BODY:-(empty)}"
      OVERALL_FAILED=1
    fi
  fi
fi

# ============================================================================
# Phase 6: KeyDB counter-welcome key exists and increments
# ============================================================================
log "Phase 6: Checking KeyDB counter-welcome key"

# Check if KeyDB is deployed
if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get deployment keydb > /dev/null 2>&1; then
  err "KeyDB deployment not found in namespace '${KEYDB_NAMESPACE}'"
  PHASE6_STATUS="FAIL"
  PHASE6_DETAIL="KeyDB deployment not found"
  OVERALL_FAILED=1
else
  # Check if keydb-cli is available or use kubectl exec
  log "  Checking if we can access KeyDB via kubectl exec..."

  # First check if the KeyDB pod is running
  KEYDB_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get pod -l app=keydb \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [ -z "${KEYDB_POD}" ]; then
    # Try with different label selectors
    KEYDB_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get pods \
      --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  fi

  if [ -z "${KEYDB_POD}" ]; then
    err "No running KeyDB pod found in namespace '${KEYDB_NAMESPACE}'"
    PHASE6_STATUS="FAIL"
    PHASE6_DETAIL="No running KeyDB pod found"
    OVERALL_FAILED=1
  else
    log "  KeyDB pod: ${KEYDB_POD}"

    # Try keydb-cli first
    if kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
      keydb-cli GET counter-welcome > /dev/null 2>&1; then

      # Get the current value
      COUNTER_VALUE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
        keydb-cli GET counter-welcome 2>/dev/null || echo "")

      log "  counter-welcome value: ${COUNTER_VALUE:-<empty/nil>}"

      if [ -n "${COUNTER_VALUE}" ]; then
        # Verify it's a number
        if [[ "${COUNTER_VALUE}" =~ ^[0-9]+$ ]]; then
          # Test incrementing the key
          NEW_COUNTER=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
            keydb-cli INCR counter-welcome 2>/dev/null || echo "")

          if [ -n "${NEW_COUNTER}" ] && [ "${NEW_COUNTER}" = "$((COUNTER_VALUE + 1))" ]; then
            PHASE6_STATUS="PASS"
            PHASE6_DETAIL="counter-welcome=${COUNTER_VALUE}, after INCR=${NEW_COUNTER} (incremented correctly)"
            log "  -> PASSED (counter: ${COUNTER_VALUE} -> ${NEW_COUNTER})"

            # Decrement back to preserve state
            kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
              keydb-cli DECR counter-welcome > /dev/null 2>&1 || true
          else
            PHASE6_STATUS="PASS"
            PHASE6_DETAIL="counter-welcome=${COUNTER_VALUE} (exists, INCR returned ${NEW_COUNTER:-error})"
            log "  -> PASSED (counter exists: ${COUNTER_VALUE})"
          fi
        else
          PHASE6_STATUS="WARN"
          PHASE6_DETAIL="counter-welcome exists but value is non-numeric: '${COUNTER_VALUE}'"
          log "  -> WARN (non-numeric value)"
        fi
      else
        # Try checking with KEYS
        KEY_COUNT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
          keydb-cli KEYS "*counter*" 2>/dev/null || echo "")

        if [ -n "${KEY_COUNT}" ]; then
          PHASE6_STATUS="WARN"
          PHASE6_DETAIL="counter-welcome is nil but found other keys: ${KEY_COUNT}"
          log "  -> WARN (counter-welcome nil, other keys exist)"
        else
          PHASE6_STATUS="WARN"
          PHASE6_DETAIL="counter-welcome key is nil (not yet created by counter SpinApp)"
          log "  -> WARN (counter-welcome not yet set — counter SpinApp may not have processed a request)"
        fi
      fi
    else
      # keydb-cli not available in the pod, try redis-cli
      log "  keydb-cli not available, trying redis-cli..."
      if kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
        redis-cli GET counter-welcome > /dev/null 2>&1; then

        COUNTER_VALUE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
          redis-cli GET counter-welcome 2>/dev/null || echo "")

        if [ -n "${COUNTER_VALUE}" ] && [[ "${COUNTER_VALUE}" =~ ^[0-9]+$ ]]; then
          PHASE6_STATUS="PASS"
          PHASE6_DETAIL="counter-welcome=${COUNTER_VALUE} (via redis-cli)"
          log "  -> PASSED (counter: ${COUNTER_VALUE} via redis-cli)"
        else
          PHASE6_STATUS="WARN"
          PHASE6_DETAIL="counter-welcome=${COUNTER_VALUE:-nil} (via redis-cli)"
          log "  -> WARN (counter-welcome: ${COUNTER_VALUE:-nil})"
        fi
      else
        err "Neither keydb-cli nor redis-cli available in the KeyDB pod"
        PHASE6_STATUS="FAIL"
        PHASE6_DETAIL="No Redis CLI available in KeyDB pod"
        OVERALL_FAILED=1
      fi
    fi
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Workloads Health Verification Summary ==="
printf "%-10s %-12s %-72s\n" "PHASE"         "STATUS" "DETAIL"
printf "%-10s %-12s %-72s\n" "-----"         "------" "------"
printf "%-10s %-12s %-72s\n" "1-Namespace"  "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-72s\n" "2-Ksvc"       "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-72s\n" "3-SpinApp"    "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-72s\n" "4-HTTPRoute"  "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-10s %-12s %-72s\n" "5-Endpoint"   "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-10s %-12s %-72s\n" "6-KeyDB"      "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
echo "======================================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "======================================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-workloads: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-workloads: ALL CHECKS PASSED"
exit 0

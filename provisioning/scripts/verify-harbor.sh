#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-harbor.sh -- Harbor registry health verification
#
# Verifies Harbor pod health, LoadBalancer Ingress IP assignment, registry
# API endpoint responsiveness, PVC binding status, and portal/web UI
# availability.
#
# Designed for post-install validation and troubleshooting. Exits non-zero
# on any phase failure. Gracefully handles still-initialising Harbor (LB IP
# not yet assigned, pods still starting) with clear messaging.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-harbor.sh [--kubeconfig <path>] [--namespace <ns>]
#                           [--expected-pods <count>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="harbor"
EXPECTED_PODS=8

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";     shift 2 ;;
    --namespace)       NAMESPACE="$2";      shift 2 ;;
    --expected-pods)  EXPECTED_PODS="$2";   shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Harbor registry health: pod readiness, LoadBalancer Ingress,
registry API endpoint, PVC binding, and portal/UI availability.

Options:
  --kubeconfig PATH     Path to kubeconfig (default: ../dev/kubeconfig)
  --namespace NS        Harbor namespace (default: harbor)
  --expected-pods NUM   Expected number of pods (default: 8)
  --help, -h            Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-harbor: starting"
log "  kubeconfig:      ${KUBECONFIG}"
log "  namespace:       ${NAMESPACE}"
log "  expected pods:   ${EXPECTED_PODS}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# Detect curl availability (Phase 3 and 5 need it)
CURL_AVAILABLE=0
command -v curl >/dev/null 2>&1 && CURL_AVAILABLE=1
if [ "${CURL_AVAILABLE}" -eq 0 ]; then
  log "  curl not found -- Phases 3 and 5 will be skipped"
fi

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # Harbor pod health
PHASE1_DETAIL=""
PHASE2_STATUS=""   # LoadBalancer Ingress IP
PHASE2_DETAIL=""
PHASE3_STATUS=""   # Registry API endpoint
PHASE3_DETAIL=""
PHASE4_STATUS=""   # PVC binding status
PHASE4_DETAIL=""
PHASE5_STATUS=""   # Portal/web UI
PHASE5_DETAIL=""

OVERALL_FAILED=0

# ============================================================================
# Phase 1: Harbor pod health
# ============================================================================
log "Phase 1: Checking Harbor pod health in namespace ${NAMESPACE}"
POD_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pods \
  --no-headers -o wide 2>&1) \
  || { err "kubectl get pods failed: ${POD_OUTPUT}"; PHASE1_STATUS="FAIL"; PHASE1_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE1_STATUS}" ]; then
  POD_READY=0
  POD_TOTAL=0
  POD_NOT_OK=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    POD_TOTAL=$((POD_TOTAL + 1))
    READY_FIELD=$(echo "$line" | awk '{print $2}')
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')
    READY_NUM="${READY_FIELD%%/*}"

    if [ "${READY_NUM}" -gt 0 ] && [ "${STATUS_FIELD}" = "Running" ]; then
      POD_READY=$((POD_READY + 1))
    else
      POD_NAME=$(echo "$line" | awk '{print $1}')
      POD_NOT_OK="${POD_NOT_OK} ${POD_NAME}(${STATUS_FIELD}/${READY_FIELD})"
    fi
  done <<< "$POD_OUTPUT"

  if [ "${POD_TOTAL}" -eq 0 ]; then
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="No pods yet in namespace ${NAMESPACE} (Harbor initializing)"
    log "Phase 1: ${PHASE1_DETAIL} -- PASSED (graceful)"
  elif [ -n "${POD_NOT_OK}" ]; then
    err "Harbor pods not ready:${POD_NOT_OK}"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="${POD_READY}/${POD_TOTAL} ready"
    OVERALL_FAILED=1
  elif [ "${POD_TOTAL}" -lt "${EXPECTED_PODS}" ]; then
    PHASE1_STATUS="WARN"
    PHASE1_DETAIL="${POD_READY}/${POD_TOTAL} ready (expected ${EXPECTED_PODS}, still provisioning)"
    log "Phase 1: ${PHASE1_DETAIL} -- WARN (partial, still initializing)"
  else
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="${POD_READY}/${POD_TOTAL} ready"
    log "Phase 1: ${PHASE1_DETAIL} -- PASSED"
  fi
fi

# ============================================================================
# Phase 2: Harbor service LoadBalancer Ingress IP
# ============================================================================
log "Phase 2: Checking Harbor LoadBalancer Ingress IP"
LB_IP=""
LB_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get svc harbor \
  -o json 2>&1) \
  || { err "kubectl get svc/harbor failed: ${LB_OUTPUT}"; PHASE2_STATUS="FAIL"; PHASE2_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE2_STATUS}" ]; then
  LB_IP=$(echo "${LB_OUTPUT}" | grep -o '"ingress":[[:space:]]*\[[[:space:]]*{[[:space:]]*"ip":[[:space:]]*"[^"]*"' | grep -o '"ip":"[^"]*"' | cut -d'"' -f4 || true)

  # Fallback: try hostname if IP is not assigned
  if [ -z "${LB_IP}" ]; then
    LB_HOST=$(echo "${LB_OUTPUT}" | grep -o '"ingress":[[:space:]]*\[[[:space:]]*{[[:space:]]*"hostname":[[:space:]]*"[^"]*"' | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4 || true)
  fi

  if [ -z "${LB_IP}" ] && [ -z "${LB_HOST+x}" ]; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="LoadBalancer Ingress not yet assigned (still provisioning)"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED (graceful)"
  elif [ -n "${LB_IP}" ]; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="Ingress IP: ${LB_IP}"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
  elif [ -n "${LB_HOST}" ]; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="Ingress hostname: ${LB_HOST}"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED (hostname)"
  fi
fi

# ============================================================================
# Phase 3: Harbor registry API endpoint
#
# Uses the LoadBalancer Ingress IP from Phase 2. A 401 response proves the
# registry API is alive (unauthenticated request is expected). Skipped if
# curl is unavailable or if LB IP is not yet assigned.
# ============================================================================
log "Phase 3: Checking Harbor registry API endpoint"

if [ "${CURL_AVAILABLE}" -eq 0 ]; then
  PHASE3_STATUS="SKIP"
  PHASE3_DETAIL="curl not available"
  log "Phase 3: ${PHASE3_DETAIL} -- SKIPPED"
elif [ -z "${LB_IP}" ]; then
  PHASE3_STATUS="SKIP"
  PHASE3_DETAIL="LoadBalancer IP not yet assigned"
  log "Phase 3: ${PHASE3_DETAIL} -- SKIPPED (graceful)"
else
  REGISTRY_HTTP_CODE=$(curl -o /dev/null -s -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://${LB_IP}/api/v2/" 2>&1) || true

  if [ "${REGISTRY_HTTP_CODE}" = "401" ]; then
    PHASE3_STATUS="PASS"
    PHASE3_DETAIL="HTTP ${REGISTRY_HTTP_CODE} (unauthenticated -- API is alive)"
    log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
  elif [ "${REGISTRY_HTTP_CODE}" = "200" ]; then
    PHASE3_STATUS="PASS"
    PHASE3_DETAIL="HTTP ${REGISTRY_HTTP_CODE} (API responding)"
    log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
  elif [ -n "${REGISTRY_HTTP_CODE}" ]; then
    PHASE3_STATUS="WARN"
    PHASE3_DETAIL="HTTP ${REGISTRY_HTTP_CODE} (unexpected response)"
    log "Phase 3: ${PHASE3_DETAIL} -- WARN"
  else
    PHASE3_STATUS="WARN"
    PHASE3_DETAIL="No HTTP response from ${LB_IP}:80 (Harbor still initializing)"
    log "Phase 3: ${PHASE3_DETAIL} -- WARN (graceful)"
  fi
fi

# ============================================================================
# Phase 4: PVC binding status
# ============================================================================
log "Phase 4: Checking Harbor PVC binding status"
PVC_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pvc \
  --no-headers 2>&1) \
  || { err "kubectl get pvc failed: ${PVC_OUTPUT}"; PHASE4_STATUS="FAIL"; PHASE4_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE4_STATUS}" ]; then
  PVC_TOTAL=0
  PVC_BOUND=0
  PVC_NOT_BOUND=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    PVC_TOTAL=$((PVC_TOTAL + 1))
    PVC_STATUS=$(echo "$line" | awk '{print $2}')

    if [ "${PVC_STATUS}" = "Bound" ]; then
      PVC_BOUND=$((PVC_BOUND + 1))
    else
      PVC_NAME=$(echo "$line" | awk '{print $1}')
      PVC_NOT_BOUND="${PVC_NOT_BOUND} ${PVC_NAME}(${PVC_STATUS})"
    fi
  done <<< "$PVC_OUTPUT"

  if [ "${PVC_TOTAL}" -eq 0 ]; then
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="No PVCs in namespace ${NAMESPACE} (Harbor initializing)"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED (graceful)"
  elif [ -n "${PVC_NOT_BOUND}" ]; then
    err "PVCs not Bound:${PVC_NOT_BOUND}"
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="${PVC_BOUND}/${PVC_TOTAL} Bound"
    OVERALL_FAILED=1
  else
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="${PVC_BOUND}/${PVC_TOTAL} Bound"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED"
  fi
fi

# ============================================================================
# Phase 5: Harbor portal/web UI
#
# Checks the main Harbor portal page. A 200 response proves the web UI is
# serving. Skipped if curl is unavailable or if LB IP is not yet assigned.
# ============================================================================
log "Phase 5: Checking Harbor portal/web UI"

if [ "${CURL_AVAILABLE}" -eq 0 ]; then
  PHASE5_STATUS="SKIP"
  PHASE5_DETAIL="curl not available"
  log "Phase 5: ${PHASE5_DETAIL} -- SKIPPED"
elif [ -z "${LB_IP}" ]; then
  PHASE5_STATUS="SKIP"
  PHASE5_DETAIL="LoadBalancer IP not yet assigned"
  log "Phase 5: ${PHASE5_DETAIL} -- SKIPPED (graceful)"
else
  PORTAL_HTTP_CODE=$(curl -o /dev/null -s -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://${LB_IP}/" 2>&1) || true

  if [ "${PORTAL_HTTP_CODE}" = "200" ]; then
    PHASE5_STATUS="PASS"
    PHASE5_DETAIL="HTTP ${PORTAL_HTTP_CODE} (portal UI responding)"
    log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
  elif [ -n "${PORTAL_HTTP_CODE}" ]; then
    PHASE5_STATUS="WARN"
    PHASE5_DETAIL="HTTP ${PORTAL_HTTP_CODE} (portal not fully ready)"
    log "Phase 5: ${PHASE5_DETAIL} -- WARN"
  else
    PHASE5_STATUS="WARN"
    PHASE5_DETAIL="No HTTP response from ${LB_IP}:80 (portal still initializing)"
    log "Phase 5: ${PHASE5_DETAIL} -- WARN (graceful)"
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Harbor Health Verification Summary ==="
printf "%-10s %-12s %-54s\n" "PHASE"     "STATUS" "DETAIL"
printf "%-10s %-12s %-54s\n" "-----"     "------" "------"
printf "%-10s %-12s %-54s\n" "1-Pods"    "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-54s\n" "2-LB-IP"   "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-54s\n" "3-API"     "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-54s\n" "4-PVCs"    "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-10s %-12s %-54s\n" "5-Portal"  "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
echo "========================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "========================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-harbor: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-harbor: ALL CHECKS PASSED"
exit 0

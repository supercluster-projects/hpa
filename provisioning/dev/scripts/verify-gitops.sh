#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-gitops.sh — Kargo + ArgoCD + Warehouse + Application verification
#
# Verifies the GitOps delivery pipeline that S06 workloads depend on:
#   Phase 1: Kargo pod health (namespace kargo)
#   Phase 2: ArgoCD pod health (namespace argocd: argocd-server,
#            argocd-repo-server, argocd-application-controller)
#   Phase 3: ArgoCD Application status (hpa-workloads exists, has
#            status.sync.status and health.status)
#   Phase 4: Kargo Warehouse availability (hpa-warehouse exists)
#   Phase 5: Harbor connectivity test (if curl available and Harbor URL
#            provided) — verify the registry API is reachable from inside
#            the cluster
#
# Each phase produces PASS / WARN / FAIL / SKIP with detail. A final summary
# table is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-gitops.sh [--kubeconfig <path>]
#           [--kargo-namespace <ns>] [--argocd-namespace <ns>]
#           [--application-name <name>] [--warehouse-name <name>]
#           [--harbor-url <url>]
#           [--expected-kargo-pods <count>] [--expected-argocd-pods <count>]
#           [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env DEV_HARBOR_URL

# ---- Internal defaults (script-internal only) -------------------------
HARBOR_URL="${DEV_HARBOR_URL}"
APPLICATION_NAME="hpa-workloads"
WAREHOUSE_NAME="hpa-warehouse"
EXPECTED_KARGO_PODS=2
EXPECTED_ARGOCD_PODS=3

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)            KUBECONFIG="$2";                shift 2 ;;
    --kargo-namespace)       KARGO_NAMESPACE="$2";           shift 2 ;;
    --argocd-namespace)      ARGOCD_NAMESPACE="$2";          shift 2 ;;
    --application-name)      APPLICATION_NAME="$2";          shift 2 ;;
    --warehouse-name)        WAREHOUSE_NAME="$2";            shift 2 ;;
    --harbor-url)            HARBOR_URL="$2";                shift 2 ;;
    --expected-kargo-pods)   EXPECTED_KARGO_PODS="$2";       shift 2 ;;
    --expected-argocd-pods)  EXPECTED_ARGOCD_PODS="$2";      shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Kargo + ArgoCD GitOps pipeline health.

Phases:
  1  Kargo pod health (namespace: kargo)
  2  ArgoCD pod health (namespace: argocd)
  3  ArgoCD Application status (hpa-workloads)
  4  Kargo Warehouse availability (hpa-warehouse)
  5  Harbor connectivity test (requires --harbor-url)

Options:
  --kubeconfig PATH                 Path to kubeconfig (default: ../opentofu/kubeconfig)
  --kargo-namespace NS              Kargo namespace (default: kargo)
  --argocd-namespace NS             ArgoCD namespace (default: argocd)
  --application-name NAME           ArgoCD Application name (default: hpa-workloads)
  --warehouse-name NAME             Kargo Warehouse name (default: hpa-warehouse)
  --harbor-url URL                  Harbor registry URL for connectivity test (default: not set, skips Phase 5)
  --expected-kargo-pods COUNT       Expected Kargo pod count (default: 2)
  --expected-argocd-pods COUNT      Expected ArgoCD pod count (default: 3)
  --help, -h                        Show this help message

Examples:
  ./verify-gitops.sh --kubeconfig /custom/path/kubeconfig
  ./verify-gitops.sh --harbor-url http://harbor.harbor.svc.cluster.local
  ./verify-gitops.sh --kargo-namespace my-kargo --argocd-namespace my-argocd
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-gitops: starting"
log "  kubeconfig:           ${KUBECONFIG}"
log "  kargo namespace:      ${KARGO_NAMESPACE}"
log "  argocd namespace:     ${ARGOCD_NAMESPACE}"
log "  application name:     ${APPLICATION_NAME}"
log "  warehouse name:       ${WAREHOUSE_NAME}"
log "  harbor-url:           ${HARBOR_URL:-<not set, Phase 5 will skip>}"
log "  expected kargo pods:  ${EXPECTED_KARGO_PODS}"
log "  expected argocd pods: ${EXPECTED_ARGOCD_PODS}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # Kargo pods
PHASE1_DETAIL=""
PHASE2_STATUS=""   # ArgoCD pods
PHASE2_DETAIL=""
PHASE3_STATUS=""   # ArgoCD Application status
PHASE3_DETAIL=""
PHASE4_STATUS=""   # Kargo Warehouse availability
PHASE4_DETAIL=""
PHASE5_STATUS=""   # Harbor connectivity
PHASE5_DETAIL=""

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

# ---- Helper: check ArgoCD Application status --------------------------------
# Usage: check_argocd_app <app_name> <namespace> <var_status> <var_detail>
check_argocd_app() {
  local app_name="$1"
  local ns="$2"
  local -n out_status="$3"
  local -n out_detail="$4"

  log "Checking ArgoCD Application '${app_name}' in namespace '${ns}'"

  # First check if the Application CRD exists
  if ! kubectl --kubeconfig "${KUBECONFIG}" get crd applications.argoproj.io > /dev/null 2>&1; then
    err "ArgoCD CRD 'applications.argoproj.io' not found"
    out_status="FAIL"
    out_detail="CRD 'applications.argoproj.io' not found"
    return 1
  fi

  # Check if the Application exists
  if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get application "${app_name}" > /dev/null 2>&1; then
    err "ArgoCD Application '${app_name}' not found in namespace '${ns}'"
    out_status="FAIL"
    out_detail="Application '${app_name}' not found"
    return 1
  fi

  # Collect sync status
  local SYNC_STATUS
  SYNC_STATUS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get application "${app_name}" \
    -o jsonpath='{.status.sync.status}' 2>&1 || echo "Unknown")

  # Collect health status
  local HEALTH_STATUS
  HEALTH_STATUS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get application "${app_name}" \
    -o jsonpath='{.status.health.status}' 2>&1 || echo "Unknown")

  # Collect operation state if syncing
  local OPERATION_STATE
  OPERATION_STATE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get application "${app_name}" \
    -o jsonpath='{.status.operationState.phase}' 2>&1 || true)

  # Collect destination info
  local DEST_NS
  DEST_NS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get application "${app_name}" \
    -o jsonpath='{.spec.destination.namespace}' 2>&1 || echo "Unknown")
  local DEST_CLUSTER
  DEST_CLUSTER=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get application "${app_name}" \
    -o jsonpath='{.spec.destination.name}' 2>&1 || echo "Unknown")

  # Determine status based on sync and health
  local detail="sync=${SYNC_STATUS}, health=${HEALTH_STATUS}, dest=${DEST_CLUSTER}/${DEST_NS}"

  if [ -n "${OPERATION_STATE}" ] && [ "${OPERATION_STATE}" != "Succeeded" ]; then
    detail="${detail}, operation=${OPERATION_STATE}"
  fi

  local app_ok=true
  if [ "${SYNC_STATUS}" = "Synced" ] && [ "${HEALTH_STATUS}" = "Healthy" ]; then
    app_ok=true
  elif [ "${SYNC_STATUS}" = "Unknown" ] || [ "${HEALTH_STATUS}" = "Unknown" ]; then
    # Application exists but status not populated yet — still settling
    app_ok=false
    out_status="WARN"
    out_detail="Application '${app_name}' exists but status not settled yet: ${detail}"
    log "  -> WARN (status settling)"
    return 0
  fi

  if [ "${app_ok}" = true ]; then
    out_status="PASS"
    out_detail="Application '${app_name}': ${detail}"
    log "  -> PASSED"
    return 0
  else
    out_status="FAIL"
    out_detail="Application '${app_name}': ${detail}"
    log "  -> FAILED"
    return 1
  fi
}

# ---- Helper: check Kargo Warehouse availability ----------------------------
# Usage: check_kargo_warehouse <warehouse_name> <namespace> <var_status> <var_detail>
check_kargo_warehouse() {
  local wh_name="$1"
  local ns="$2"
  local -n out_status="$3"
  local -n out_detail="$4"

  log "Checking Kargo Warehouse '${wh_name}' in namespace '${ns}'"

  # Check if the Warehouse CRD exists
  if ! kubectl --kubeconfig "${KUBECONFIG}" get crd warehouses.kargo.akuity.io > /dev/null 2>&1; then
    err "Kargo CRD 'warehouses.kargo.akuity.io' not found"
    out_status="FAIL"
    out_detail="CRD 'warehouses.kargo.akuity.io' not found"
    return 1
  fi

  # Check if the namespace exists
  if ! kubectl --kubeconfig "${KUBECONFIG}" get ns "${ns}" > /dev/null 2>&1; then
    err "Namespace '${ns}' not found"
    out_status="FAIL"
    out_detail="Namespace '${ns}' not found"
    return 1
  fi

  # Check if the Warehouse exists
  if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get warehouse "${wh_name}" > /dev/null 2>&1; then
    err "Kargo Warehouse '${wh_name}' not found in namespace '${ns}'"
    out_status="FAIL"
    out_detail="Warehouse '${wh_name}' not found"
    return 1
  fi

  # Collect Warehouse details
  local WH_SUB_REPO
  WH_SUB_REPO=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get warehouse "${wh_name}" \
    -o jsonpath='{.spec.subscriptions[0].image.repoURL}' 2>/dev/null || echo "Unknown")

  local WH_SUB_STRATEGY
  WH_SUB_STRATEGY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get warehouse "${wh_name}" \
    -o jsonpath='{.spec.subscriptions[0].image.imageSelectionStrategy}' 2>/dev/null || echo "Unknown")

  local WH_FREIGHT_POLICY
  WH_FREIGHT_POLICY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get warehouse "${wh_name}" \
    -o jsonpath='{.spec.freightCreationPolicy}' 2>/dev/null || echo "Unknown")

  local WH_AGE
  WH_AGE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get warehouse "${wh_name}" \
    -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)

  local detail="repo=${WH_SUB_REPO}, strategy=${WH_SUB_STRATEGY}, freightPolicy=${WH_FREIGHT_POLICY}"
  if [ -n "${WH_AGE}" ]; then
    detail="${detail}, created=${WH_AGE}"
  fi

  out_status="PASS"
  out_detail="Warehouse '${wh_name}': ${detail}"
  log "  -> PASSED"
  return 0
}

# ---- Helper: Harbor connectivity test --------------------------------------
# Usage: check_harbor_connectivity <harbor_url> <var_status> <var_detail>
check_harbor_connectivity() {
  local harbor_url="$1"
  local -n out_status="$2"
  local -n out_detail="$3"

  log "Checking Harbor connectivity at '${harbor_url}'"

  # Check if curl is available
  if ! command -v curl >/dev/null 2>&1; then
    out_status="SKIP"
    out_detail="curl not available in PATH"
    log "  -> SKIP (curl not found)"
    return 0
  fi

  # If no Harbor URL provided, skip
  if [ -z "${harbor_url}" ]; then
    out_status="SKIP"
    out_detail="no Harbor URL provided (use --harbor-url)"
    log "  -> SKIP (no URL provided)"
    return 0
  fi

  # Try the Harbor health endpoint first (Harbor v2 has /healthz,
  # older versions have /api/v2.0/health or the root /api/health)
  local RESPONSE
  local HTTP_CODE

  # Try healthz endpoint (most common)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
    "${harbor_url}/healthz" 2>&1 || echo "000")

  if [ "${HTTP_CODE}" = "200" ]; then
    out_status="PASS"
    out_detail="Harbor API reachable at '${harbor_url}' (healthz: ${HTTP_CODE})"
    log "  -> PASSED"
    return 0
  fi

  # Try API v2 health endpoint
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
    "${harbor_url}/api/v2.0/health" 2>&1 || echo "000")

  if [ "${HTTP_CODE}" = "200" ]; then
    # Also try to fetch the health payload for richer detail
    local HEALTH_PAYLOAD
    HEALTH_PAYLOAD=$(curl -s --connect-timeout 5 "${harbor_url}/api/v2.0/health" 2>&1 | head -c 200 || true)
    out_status="PASS"
    out_detail="Harbor API reachable at '${harbor_url}' (api/v2.0/health: ${HTTP_CODE})"
    if [ -n "${HEALTH_PAYLOAD}" ]; then
      out_detail="${out_detail} — ${HEALTH_PAYLOAD}"
    fi
    log "  -> PASSED"
    return 0
  fi

  # Try the root API endpoint as fallback
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
    "${harbor_url}/api/health" 2>&1 || echo "000")

  if [ "${HTTP_CODE}" = "200" ]; then
    out_status="PASS"
    out_detail="Harbor API reachable at '${harbor_url}' (api/health: ${HTTP_CODE})"
    log "  -> PASSED"
    return 0
  fi

  # If we got any HTTP response at all (not a connection failure), report WARN
  if [ "${HTTP_CODE}" != "000" ]; then
    out_status="WARN"
    out_detail="Harbor at '${harbor_url}' responded with HTTP ${HTTP_CODE} on healthz but not 200"
    log "  -> WARN (HTTP ${HTTP_CODE})"
    return 0
  fi

  # Connection failure
  err "Harbor at '${harbor_url}' not reachable (connection timeout)"
  out_status="FAIL"
  out_detail="Harbor at '${harbor_url}' not reachable (connection timeout)"
  return 1
}

# ============================================================================
# Phase 1: Kargo pod health (namespace: kargo)
# ============================================================================
log "Phase 1: Kargo pod health"
if check_pod_health "${KARGO_NAMESPACE}" "${EXPECTED_KARGO_PODS}" PHASE1_STATUS PHASE1_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: ArgoCD pod health (namespace: argocd)
# ============================================================================
log "Phase 2: ArgoCD pod health"
# First check if namespace exists; ArgoCD pods expected include:
# argocd-server, argocd-repo-server, argocd-application-controller, argocd-redis
if kubectl --kubeconfig "${KUBECONFIG}" get ns "${ARGOCD_NAMESPACE}" > /dev/null 2>&1; then
  if check_pod_health "${ARGOCD_NAMESPACE}" "${EXPECTED_ARGOCD_PODS}" PHASE2_STATUS PHASE2_DETAIL; then
    : # already set
  else
    OVERALL_FAILED=1
  fi
else
  err "Namespace '${ARGOCD_NAMESPACE}' not found"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="Namespace '${ARGOCD_NAMESPACE}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 3: ArgoCD Application status (hpa-workloads)
# ============================================================================
log "Phase 3: ArgoCD Application status"
if check_argocd_app "${APPLICATION_NAME}" "${ARGOCD_NAMESPACE}" PHASE3_STATUS PHASE3_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 4: Kargo Warehouse availability (hpa-warehouse)
# ============================================================================
log "Phase 4: Kargo Warehouse availability"
if check_kargo_warehouse "${WAREHOUSE_NAME}" "${KARGO_NAMESPACE}" PHASE4_STATUS PHASE4_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 5: Harbor connectivity test (if curl available and Harbor URL provided)
# ============================================================================
log "Phase 5: Harbor connectivity test"
if check_harbor_connectivity "${HARBOR_URL}" PHASE5_STATUS PHASE5_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== GitOps Health Verification Summary ==="
printf "%-10s %-12s %-72s\n" "PHASE"        "STATUS" "DETAIL"
printf "%-10s %-12s %-72s\n" "-----"        "------" "------"
printf "%-10s %-12s %-72s\n" "1-Kargo"     "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-72s\n" "2-ArgoCD"    "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-72s\n" "3-App"       "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-72s\n" "4-Warehouse" "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-10s %-12s %-72s\n" "5-Harbor"    "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
echo "======================================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "======================================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-gitops: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-gitops: ALL CHECKS PASSED"
exit 0

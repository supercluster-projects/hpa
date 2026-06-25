#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-runtimes.sh — Core runtime health verification
#
# Verifies all core runtimes that downstream components depend on:
#   Phase 1: cert-manager pod health (namespace cert-manager)
#   Phase 2: Knative Serving pod health (namespace knative-serving)
#   Phase 3: Knative CRD availability (ksvc, configuration, revision, route)
#   Phase 4: SpinKube operator pod health (namespace spin-operator)
#   Phase 5: SpinKube CRD availability (spinapp)
#   Phase 6: KeyDB pod health (namespace keydb)
#   Phase 7: KeyDB PVC binding status
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-runtimes.sh [--kubeconfig <path>]
#           [--expected-runtime-pods cert-manager:3,knative-serving:2,...]
#           [--wait-timeout <seconds>] [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# Parse expected-runtime-pods argument
# Input format: "cert-manager:3,knative-serving:2,spin-operator:1,keydb:2"
parse_expected_pods() {
  local input="$1"
  IFS=',' read -ra PAIRS <<< "$input"
  for pair in "${PAIRS[@]}"; do
    local ns="${pair%%:*}"
    local count="${pair##*:}"
    if [ -n "$ns" ] && [ -n "$count" ]; then
      EXPECTED_PODS["$ns"]="$count"
    fi
  done
}

# ---- Required environment variables (fail fast if missing from .env) ---

# ---- Internal defaults (script-internal only) -------------------------
WAIT_TIMEOUT=120
EXPECTED_CERT_MGR=3
EXPECTED_KNATIVE=5
SPIN_NS="spin-operator"
EXPECTED_SPIN=1
EXPECTED_KEYDB=1

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)             KUBECONFIG="$2";              shift 2 ;;
    --expected-runtime-pods)  parse_expected_pods "$2";     shift 2 ;;
    --wait-timeout)           WAIT_TIMEOUT="$2";            shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify core runtime health: cert-manager, Knative Serving, SpinKube, and KeyDB.

Phases:
  1  cert-manager pod health (namespace: cert-manager)
  2  Knative Serving pod health (namespace: knative-serving)
  3  Knative CRD availability (ksvc, configuration, revision, route)
  4  SpinKube operator pod health (namespace: spin-operator)
  5  SpinKube CRD availability (spinapp)
  6  KeyDB pod health (namespace: keydb)
  7  KeyDB PVC binding status

Options:
  --kubeconfig PATH               Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --expected-runtime-pods LIST    Comma-separated namespace:count pairs
                                    (default: cert-manager:3,knative-serving:2,
                                              spin-operator:1,keydb:2)
  --wait-timeout SECONDS          Max seconds to wait for pods/CRDs to appear
                                    (default: 120)
  --help, -h                      Show this help message

Examples:
  ./verify-runtimes.sh --kubeconfig /custom/path/kubeconfig
  ./verify-runtimes.sh --expected-runtime-pods "cert-manager:3,knative-serving:2"
  ./verify-runtimes.sh --wait-timeout 300
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-runtimes: starting"
log "  kubeconfig:      ${KUBECONFIG}"
log "  wait timeout:    ${WAIT_TIMEOUT}s"
for ns in "${!EXPECTED_PODS[@]}"; do
  log "  ${ns}: expected ${EXPECTED_PODS[$ns]} pod(s)"
done

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # cert-manager pods
PHASE1_DETAIL=""
PHASE2_STATUS=""   # Knative Serving pods
PHASE2_DETAIL=""
PHASE3_STATUS=""   # Knative CRDs
PHASE3_DETAIL=""
PHASE4_STATUS=""   # SpinKube operator pods
PHASE4_DETAIL=""
PHASE5_STATUS=""   # SpinKube CRDs
PHASE5_DETAIL=""
PHASE6_STATUS=""   # KeyDB pods
PHASE6_DETAIL=""
PHASE7_STATUS=""   # KeyDB PVC binding
PHASE7_DETAIL=""

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

# ---- Helper: check PVC binding status -------------------------------------
# Usage: check_pvc_bound <namespace> <var_status> <var_detail>
check_pvc_bound() {
  local ns="$1"
  local -n out_status="$2"
  local -n out_detail="$3"

  log "Checking PVC binding status in namespace '${ns}'"

  local PVC_OUTPUT
  PVC_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pvc --no-headers 2>&1) \
    || { err "kubectl get pvc in '${ns}' failed: ${PVC_OUTPUT}"; out_status="FAIL"; out_detail="kubectl error"; return 1; }

  local TOTAL=0
  local BOUND=0
  local NOT_BOUND=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    TOTAL=$((TOTAL + 1))
    # Column 2 is STATUS in kubectl get pvc --no-headers output
    local PVC_STATUS
    PVC_STATUS=$(echo "$line" | awk '{print $2}')
    local PVC_NAME
    PVC_NAME=$(echo "$line" | awk '{print $1}')

    if [ "${PVC_STATUS}" = "Bound" ]; then
      local VOLUME
      VOLUME=$(echo "$line" | awk '{print $3}')
      BOUND=$((BOUND + 1))
      log "  PVC '${PVC_NAME}' -> Bound to '${VOLUME}'"
    else
      NOT_BOUND="${NOT_BOUND} ${PVC_NAME}(${PVC_STATUS})"
    fi
  done <<< "${PVC_OUTPUT}"

  if [ -n "${NOT_BOUND}" ]; then
    err "PVCs not Bound in '${ns}':${NOT_BOUND}"
    out_status="FAIL"
    out_detail="${BOUND}/${TOTAL} Bound"
    return 1
  elif [ "${TOTAL}" -eq 0 ]; then
    # No PVCs is acceptable — KeyDB may not have created them yet
    out_status="WARN"
    out_detail="0 PVCs found (runtime may not have created them yet)"
    log "  -> WARN (no PVCs)"
    return 0
  elif [ "${BOUND}" -eq "${TOTAL}" ]; then
    out_status="PASS"
    out_detail="${BOUND}/${TOTAL} Bound"
    log "  -> PASSED"
    return 0
  else
    err "PVC binding count mismatch in '${ns}': ${BOUND}/${TOTAL} Bound"
    out_status="FAIL"
    out_detail="${BOUND}/${TOTAL} Bound"
    return 1
  fi
}

# ============================================================================
# Phase 1: cert-manager pod health (namespace: cert-manager)
# ============================================================================
log "Phase 1: cert-manager pod health"
EXPECTED_CERT_MGR="${EXPECTED_PODS["cert-manager"]:-3}"
if check_pod_health "cert-manager" "${EXPECTED_CERT_MGR}" PHASE1_STATUS PHASE1_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: Knative Serving pod health (namespace: knative-serving)
# ============================================================================
log "Phase 2: Knative Serving pod health"
EXPECTED_KNATIVE="${EXPECTED_PODS["knative-serving"]:-2}"
if check_pod_health "knative-serving" "${EXPECTED_KNATIVE}" PHASE2_STATUS PHASE2_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 3: Knative CRD availability (ksvc, configuration, revision, route)
# ============================================================================
log "Phase 3: Knative CRD availability"
PHASE3_CRDS=(
  "services.serving.knative.dev:ksvc"
  "configurations.serving.knative.dev:configuration"
  "revisions.serving.knative.dev:revision"
  "routes.serving.knative.dev:route"
)
PHASE3_MISSING=""
for crd_entry in "${PHASE3_CRDS[@]}"; do
  crd_full="${crd_entry%%:*}"
  crd_short="${crd_entry##*:}"

  if kubectl --kubeconfig "${KUBECONFIG}" get crd "${crd_full}" > /dev/null 2>&1; then
    log "  CRD '${crd_full}': FOUND"
  else
    err "CRD '${crd_full}' does not exist"
    PHASE3_MISSING="${PHASE3_MISSING} ${crd_short}"
  fi
done

if [ -z "${PHASE3_MISSING}" ]; then
  PHASE3_STATUS="PASS"
  PHASE3_DETAIL="all 4 Knative CRDs found (ksvc, configuration, revision, route)"
  log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
else
  PHASE3_STATUS="FAIL"
  PHASE3_DETAIL="missing CRDs:${PHASE3_MISSING}"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 4: SpinKube operator pod health (namespace: spin-operator)
# ============================================================================
log "Phase 4: SpinKube operator pod health"
# Check for spin-operator namespace; fall back to spinkube if not found
SPIN_NS="spin-operator"
if ! kubectl --kubeconfig "${KUBECONFIG}" get ns "${SPIN_NS}" > /dev/null 2>&1; then
  if kubectl --kubeconfig "${KUBECONFIG}" get ns "spinkube" > /dev/null 2>&1; then
    SPIN_NS="spinkube"
    log "  Using namespace 'spinkube' instead of 'spin-operator'"
  fi
fi

EXPECTED_SPIN="${EXPECTED_PODS["${SPIN_NS}"]:-1}"
if check_pod_health "${SPIN_NS}" "${EXPECTED_SPIN}" PHASE4_STATUS PHASE4_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 5: SpinKube CRD availability (spinapp)
# ============================================================================
log "Phase 5: SpinKube CRD availability"
if check_crd "spinapps.core.spinoperator.dev" "spinapp" PHASE5_STATUS PHASE5_DETAIL; then
  : # already set
else
  # Try alternative CRD names (some operator versions use different API groups)
  if check_crd "spinapps.spinoperator.dev" "spinapp (alt)" PHASE5_STATUS PHASE5_DETAIL; then
    : # already set
  else
    PHASE5_STATUS="FAIL"
    PHASE5_DETAIL="CRD spinapps not found (tried core.spinoperator.dev and spinoperator.dev)"
    OVERALL_FAILED=1
  fi
fi

# ============================================================================
# Phase 6: KeyDB pod health (namespace: keydb)
# ============================================================================
log "Phase 6: KeyDB pod health"
EXPECTED_KEYDB="${EXPECTED_PODS["keydb"]:-2}"
if check_pod_health "keydb" "${EXPECTED_KEYDB}" PHASE6_STATUS PHASE6_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 7: KeyDB PVC binding status (namespace: keydb)
# ============================================================================
log "Phase 7: KeyDB PVC binding status"
if check_pvc_bound "keydb" PHASE7_STATUS PHASE7_DETAIL; then
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
echo "=== Runtime Health Verification Summary ==="
printf "%-10s %-12s %-54s\n" "PHASE"      "STATUS" "DETAIL"
printf "%-10s %-12s %-54s\n" "-----"      "------" "------"
printf "%-10s %-12s %-54s\n" "1-CertMgr"  "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-54s\n" "2-Knative"  "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-54s\n" "3-Kn-CRDs"  "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-54s\n" "4-SpinPod"  "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-10s %-12s %-54s\n" "5-SpinCRD"  "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-10s %-12s %-54s\n" "6-KeyDB"    "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
printf "%-10s %-12s %-54s\n" "7-KeyDB-PVC" "${PHASE7_STATUS}" "${PHASE7_DETAIL}"
echo "========================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "========================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-runtimes: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-runtimes: ALL CHECKS PASSED"
exit 0

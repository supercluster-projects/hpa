#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-cilium.sh — Cilium CNI health verification
#
# Verifies Cilium agent pod health, agent count, CiliumLoadBalancerIPPool CRD
# and object state, CiliumL2AnnouncementPolicy CRD and object state, and
# optionally runs cilium status if the cilium CLI is available.
#
# Designed for post-install validation and troubleshooting. Exits non-zero
# on any phase failure. All logging goes to stderr; the final summary table
# goes to stdout.
#
# Usage: ./verify-cilium.sh [--kubeconfig <path>] [--expected-nodes <count>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---

# ---- Internal defaults (script-internal only) -------------------------
EXPECTED_NODES=4

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";     shift 2 ;;
    --expected-nodes) EXPECTED_NODES="$2"; shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Cilium CNI health, CRD state, and agent readiness.

Options:
  --kubeconfig PATH        Path to kubeconfig (default: ../dev/kubeconfig)
  --expected-nodes COUNT   Expected number of Cilium agent pods (default: 4)
  --help, -h               Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-cilium: starting"
log "  kubeconfig:      ${KUBECONFIG}"
log "  expected nodes:  ${EXPECTED_NODES}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# Optional: detect cilium CLI
CILIUM_CLI=false
if command -v cilium >/dev/null 2>&1; then
  CILIUM_CLI=true
  log "  cilium CLI: found"
else
  log "  cilium CLI: not found (Phase 5 will be skipped)"
fi

# ---- Results accumulator --------------------------------------------------
# Tracks per-phase status for the summary table
PHASE1_STATUS=""  # Cilium agent pods
PHASE1_DETAIL=""
PHASE2_STATUS=""  # Agent count
PHASE2_DETAIL=""
PHASE3_STATUS=""  # LB pool
PHASE3_DETAIL=""
PHASE4_STATUS=""  # L2 policy
PHASE4_DETAIL=""
PHASE5_STATUS=""  # cilium status (optional)
PHASE5_DETAIL=""

OVERALL_FAILED=0

# ============================================================================
# Phase 1: Cilium agent pod health
# ============================================================================
log "Phase 1: Checking Cilium agent pod health"
PHASE1_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n kube-system get pods -l k8s-app=cilium -o wide --no-headers 2>&1) \
  || { err "kubectl get cilium pods failed: ${PHASE1_OUTPUT}"; PHASE1_STATUS="FAIL"; PHASE1_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE1_STATUS}" ]; then
  READY_COUNT=0
  TOTAL_COUNT=0
  NOT_RUNNING=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    # Column 2 is READY (e.g. "1/1"), Column 3 is STATUS (e.g. "Running")
    READY_FIELD=$(echo "$line" | awk '{print $2}')
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')

    # Parse "N/M" ready count
    READY_NUM="${READY_FIELD%%/*}"
    TOTAL_NUM="${READY_FIELD##*/}"

    if [ "${READY_NUM}" = "${TOTAL_NUM}" ] && [ "${STATUS_FIELD}" = "Running" ]; then
      READY_COUNT=$((READY_COUNT + 1))
    else
      POD_NAME=$(echo "$line" | awk '{print $1}')
      NOT_RUNNING="${NOT_RUNNING} ${POD_NAME}(${STATUS_FIELD}/${READY_FIELD})"
    fi
  done <<< "$PHASE1_OUTPUT"

  if [ -n "${NOT_RUNNING}" ]; then
    err "Cilium pods not fully ready:${NOT_RUNNING}"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="${READY_COUNT}/${TOTAL_COUNT} ready"
    OVERALL_FAILED=1
  elif [ "${TOTAL_COUNT}" -eq 0 ]; then
    err "No Cilium agent pods found"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="0 pods"
    OVERALL_FAILED=1
  else
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="${READY_COUNT}/${TOTAL_COUNT} ready"
    log "Phase 1: ${PHASE1_DETAIL} — PASSED"
  fi
fi

# ============================================================================
# Phase 2: Cilium agent count match
# ============================================================================
log "Phase 2: Checking Cilium agent count (expected ${EXPECTED_NODES})"
AGENT_COUNT=$(kubectl --kubeconfig "${KUBECONFIG}" -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | grep -c "Running" || true)

if [ "${AGENT_COUNT}" -eq "${EXPECTED_NODES}" ]; then
  PHASE2_STATUS="PASS"
  PHASE2_DETAIL="${AGENT_COUNT}/${EXPECTED_NODES}"
  log "Phase 2: ${PHASE2_DETAIL} — PASSED"
else
  err "Expected ${EXPECTED_NODES} cilium agent(s), found ${AGENT_COUNT}"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="${AGENT_COUNT}/${EXPECTED_NODES}"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 3: CiliumLoadBalancerIPPool CRD and object
# ============================================================================
log "Phase 3: Checking CiliumLoadBalancerIPPool"

if kubectl --kubeconfig "${KUBECONFIG}" get crd ciliumloadbalancerippools.cilium.io > /dev/null 2>&1; then
  log "  CRD 'ciliumloadbalancerippools.cilium.io': FOUND"
else
  err "CRD 'ciliumloadbalancerippools.cilium.io' does not exist — Cilium may not support L2 announcements"
  PHASE3_STATUS="FAIL"
  PHASE3_DETAIL="CRD not found"
  OVERALL_FAILED=1
fi

if [ -z "${PHASE3_STATUS}" ]; then
  POOL_OBJECT=$(kubectl --kubeconfig "${KUBECONFIG}" get ciliumloadbalancerippool hpa-dev-lb-pool -o json 2>&1) \
    || { err "CiliumLoadBalancerIPPool 'hpa-dev-lb-pool' not found: ${POOL_OBJECT}"; PHASE3_STATUS="FAIL"; PHASE3_DETAIL="pool not found"; OVERALL_FAILED=1; }

  if [ -z "${PHASE3_STATUS}" ]; then
    # Check for ready condition
    POOL_READY=$(echo "${POOL_OBJECT}" | grep -o '"type":"Ready"' || true)
    if [ -n "${POOL_READY}" ]; then
      POOL_STATUS=$(echo "${POOL_OBJECT}" | grep -o '"status":"[^"]*"' | head -1 || echo '"status":"unknown"')
      PHASE3_STATUS="PASS"
      PHASE3_DETAIL="pool found, ${POOL_STATUS}"
      log "Phase 3: ${PHASE3_DETAIL} — PASSED"
    else
      # Pool exists but may not have conditions yet (Cilium still initializing)
      PHASE3_STATUS="PASS"
      PHASE3_DETAIL="pool found (awaiting conditions)"
      log "Phase 3: ${PHASE3_DETAIL} — PASSED (object exists)"
    fi
  fi
fi

# ============================================================================
# Phase 4: CiliumL2AnnouncementPolicy CRD and object
# ============================================================================
log "Phase 4: Checking CiliumL2AnnouncementPolicy"

if kubectl --kubeconfig "${KUBECONFIG}" get crd ciliuml2announcementpolicies.cilium.io > /dev/null 2>&1; then
  log "  CRD 'ciliuml2announcementpolicies.cilium.io': FOUND"
else
  err "CRD 'ciliuml2announcementpolicies.cilium.io' does not exist"
  PHASE4_STATUS="FAIL"
  PHASE4_DETAIL="CRD not found"
  OVERALL_FAILED=1
fi

if [ -z "${PHASE4_STATUS}" ]; then
  POLICY_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" get ciliuml2announcementpolicy hpa-dev-l2-policy 2>&1) \
    || { err "CiliumL2AnnouncementPolicy 'hpa-dev-l2-policy' not found: ${POLICY_OUTPUT}"; PHASE4_STATUS="FAIL"; PHASE4_DETAIL="policy not found"; OVERALL_FAILED=1; }

  if [ -z "${PHASE4_STATUS}" ]; then
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="policy found"
    log "Phase 4: ${PHASE4_DETAIL} — PASSED"
  fi
fi

# ============================================================================
# Phase 5: Optional cilium CLI status
# ============================================================================
if [ "${CILIUM_CLI}" = true ]; then
  log "Phase 5: Running cilium status --brief"
  CILIUM_STATUS_OUTPUT=$(cilium status --brief 2>&1) || true

  if echo "${CILIUM_STATUS_OUTPUT}" | grep -qi "ok" || echo "${CILIUM_STATUS_OUTPUT}" | grep -qi "healthy"; then
    PHASE5_STATUS="PASS"
    PHASE5_DETAIL="cilium status healthy"
    log "Phase 5: cilium status — PASSED"
  elif echo "${CILIUM_STATUS_OUTPUT}" | grep -qi "warning"; then
    # Warnings are acceptable but notable
    PHASE5_STATUS="WARN"
    PHASE5_DETAIL="cilium status has warnings"
    log "Phase 5: cilium status — WARN (see above)"
  else
    PHASE5_STATUS="FAIL"
    PHASE5_DETAIL="cilium status not healthy"
    err "cilium status --brief returned: ${CILIUM_STATUS_OUTPUT}"
    OVERALL_FAILED=1
  fi
else
  # cilium CLI not available — skip gracefully
  PHASE5_STATUS="SKIP"
  PHASE5_DETAIL="cilium CLI not found"
  log "Phase 5: skipped (cilium CLI not available)"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Cilium Health Verification Summary ==="
printf "%-10s %-12s %-40s\n" "PHASE" "STATUS" "DETAIL"
printf "%-10s %-12s %-40s\n" "-----" "------" "------"
printf "%-10s %-12s %-40s\n" "1-Agents"  "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-40s\n" "2-Count"   "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-40s\n" "3-LB-Pool" "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-40s\n" "4-L2-Pol"  "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-10s %-12s %-40s\n" "5-CLI"     "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
echo "=========================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "=========================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-cilium: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-cilium: ALL CHECKS PASSED"
exit 0

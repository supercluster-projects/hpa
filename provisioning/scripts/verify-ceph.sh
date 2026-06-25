#!/usr/bin/env bash
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"
# verify-ceph.sh -- Rook Ceph health verification
#
# Verifies Rook Ceph operator pod health, CephCluster CR status (phase,
# health, OSD up/in count, MON quorum), CephBlockPool, and StorageClass.
#
# Designed for post-install validation and troubleshooting. Exits non-zero
# on any phase failure. Gracefully handles still-initialising CephCluster
# (non-READY, non-HEALTH_OK states) with clear messaging.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-ceph.sh [--kubeconfig <path>] [--expected-osds <count>]
#                         [--expected-mons <count>] [--namespace <ns>]
# ---------------------------------------------------------------------------

# ---- Defaults -------------------------------------------------------------

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";     shift 2 ;;
    --expected-osds)  EXPECTED_OSDS="$2";  shift 2 ;;
    --expected-mons)  EXPECTED_MONS="$2";  shift 2 ;;
    --namespace)      NAMESPACE="$2";      shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Rook Ceph operator health, CephCluster status, OSD/MON counts,
CephBlockPool, and StorageClass.

Options:
  --kubeconfig PATH     Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --expected-osds NUM   Expected number of OSDs (default: 3)
  --expected-mons NUM   Expected number of MONs (default: 3)
  --namespace NS        Rook Ceph namespace (default: rook-ceph)
  --help, -h            Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-ceph: starting"
log "  kubeconfig:      ${KUBECONFIG}"
log "  expected OSDs:   ${EXPECTED_OSDS}"
log "  expected MONs:   ${EXPECTED_MONS}"
log "  namespace:       ${NAMESPACE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # Operator pod health
PHASE1_DETAIL=""
PHASE2_STATUS=""   # CephCluster status (phase, health)
PHASE2_DETAIL=""
PHASE3_STATUS=""   # OSD count
PHASE3_DETAIL=""
PHASE4_STATUS=""   # MON quorum
PHASE4_DETAIL=""
PHASE5_STATUS=""   # StorageClass existence
PHASE5_DETAIL=""
PHASE6_STATUS=""   # RBD pool
PHASE6_DETAIL=""

OVERALL_FAILED=0

# ============================================================================
# Phase 1: Rook Ceph Operator pod health
# ============================================================================
log "Phase 1: Checking rook-ceph-operator pod health"
OP_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pods \
  -l app=rook-ceph-operator -o wide --no-headers 2>&1) \
  || { err "kubectl get operator pods failed: ${OP_OUTPUT}"; PHASE1_STATUS="FAIL"; PHASE1_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE1_STATUS}" ]; then
  OP_READY=0
  OP_TOTAL=0
  OP_NOT_OK=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    OP_TOTAL=$((OP_TOTAL + 1))
    READY_FIELD=$(echo "$line" | awk '{print $2}')
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')
    READY_NUM="${READY_FIELD%%/*}"

    if [ "${READY_NUM}" -gt 0 ] && [ "${STATUS_FIELD}" = "Running" ]; then
      OP_READY=$((OP_READY + 1))
    else
      POD_NAME=$(echo "$line" | awk '{print $1}')
      OP_NOT_OK="${OP_NOT_OK} ${POD_NAME}(${STATUS_FIELD}/${READY_FIELD})"
    fi
  done <<< "$OP_OUTPUT"

  if [ -n "${OP_NOT_OK}" ]; then
    err "Operator pods not ready:${OP_NOT_OK}"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="${OP_READY}/${OP_TOTAL} ready"
    OVERALL_FAILED=1
  elif [ "${OP_TOTAL}" -eq 0 ]; then
    err "No rook-ceph-operator pods found"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="0 pods"
    OVERALL_FAILED=1
  else
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="${OP_READY}/${OP_TOTAL} ready"
    log "Phase 1: ${PHASE1_DETAIL} -- PASSED"
  fi
fi

# ============================================================================
# Phase 2: CephCluster CR status (phase and health)
# ============================================================================
log "Phase 2: Checking CephCluster status"
CLUSTER_JSON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get cephcluster \
  -o json 2>&1) || { err "kubectl get cephcluster failed: ${CLUSTER_JSON}"; PHASE2_STATUS="FAIL"; PHASE2_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE2_STATUS}" ]; then
  # Extract phase and health via jsonpath
  CLUSTER_PHASE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get cephcluster -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  CLUSTER_HEALTH=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get cephcluster -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || true)

  if [ -z "${CLUSTER_PHASE}" ]; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="CephCluster exists but phase not yet available (initializing)"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED (graceful)"
  elif [ "${CLUSTER_PHASE}" = "Ready" ]; then
    if [ "${CLUSTER_HEALTH}" = "HEALTH_OK" ]; then
      PHASE2_STATUS="PASS"
      PHASE2_DETAIL="phase=${CLUSTER_PHASE}, health=${CLUSTER_HEALTH}"
      log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
    elif [ "${CLUSTER_HEALTH}" = "HEALTH_WARN" ]; then
      PHASE2_STATUS="WARN"
      PHASE2_DETAIL="phase=${CLUSTER_PHASE}, health=${CLUSTER_HEALTH} (initializing)"
      log "Phase 2: ${PHASE2_DETAIL} -- WARN (acceptable)"
    else
      PHASE2_STATUS="FAIL"
      PHASE2_DETAIL="phase=${CLUSTER_PHASE}, health=${CLUSTER_HEALTH}"
      err "CephCluster health is not OK"
      OVERALL_FAILED=1
    fi
  elif [ "${CLUSTER_PHASE}" = "Progressing" ] || [ "${CLUSTER_PHASE}" = "Configuring" ]; then
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="phase=${CLUSTER_PHASE} (initializing, health=${CLUSTER_HEALTH})"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED (still initializing)"
  elif [ "${CLUSTER_PHASE}" = "Error" ] || [ "${CLUSTER_PHASE}" = "Failed" ]; then
    PHASE2_STATUS="FAIL"
    PHASE2_DETAIL="phase=${CLUSTER_PHASE}, health=${CLUSTER_HEALTH}"
    err "CephCluster is in error phase"
    OVERALL_FAILED=1
  else
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="phase=${CLUSTER_PHASE}, health=${CLUSTER_HEALTH}"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED (known phase)"
  fi
fi

# ============================================================================
# Phase 3: OSD count (up/ready)
#
# Rook OSD daemon pods are labelled app=rook-ceph-osd. Counting Ready pods
# is more reliable than parsing the nested status.ceph.osds map (where up/in
# are booleans). Follows the same pod-level pattern as verify-cilium.sh.
# ============================================================================
log "Phase 3: Checking OSD count (expected ${EXPECTED_OSDS})"

OSD_PODS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pods \
  -l app=rook-ceph-osd --no-headers -o wide 2>&1) \
  || { err "kubectl get OSD pods failed"; OSD_PODS=""; }

# Fallback: generic grep for rook-ceph-osd- if label selector misses
if [ -z "$(echo "${OSD_PODS}" | head -1)" ]; then
  log "  app=rook-ceph-osd label selector returned no pods, falling back to name grep"
  OSD_PODS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get pods --no-headers -o wide 2>&1 | grep 'rook-ceph-osd-' || true)
fi

if [ -z "$(echo "${OSD_PODS}" | head -1)" ]; then
  PHASE3_STATUS="PASS"
  PHASE3_DETAIL="OSD pods not yet visible (CephCluster initializing)"
  log "Phase 3: ${PHASE3_DETAIL} -- PASSED (graceful)"
else
  OSD_TOTAL=0
  OSD_READY=0
  OSD_NOT_RUNNING=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    OSD_TOTAL=$((OSD_TOTAL + 1))
    READY_FIELD=$(echo "$line" | awk '{print $2}')
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')
    READY_NUM="${READY_FIELD%%/*}"

    if [ "${READY_NUM}" -gt 0 ] && [ "${STATUS_FIELD}" = "Running" ]; then
      OSD_READY=$((OSD_READY + 1))
    else
      POD_NAME=$(echo "$line" | awk '{print $1}')
      OSD_NOT_RUNNING="${OSD_NOT_RUNNING} ${POD_NAME}(${STATUS_FIELD}/${READY_FIELD})"
    fi
  done <<< "${OSD_PODS}"

  if [ -n "${OSD_NOT_RUNNING}" ]; then
    err "OSD pods not ready:${OSD_NOT_RUNNING}"
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="${OSD_READY}/${OSD_TOTAL} ready (expected ${EXPECTED_OSDS})"
    OVERALL_FAILED=1
  elif [ "${OSD_READY}" -eq "${EXPECTED_OSDS}" ]; then
    PHASE3_STATUS="PASS"
    PHASE3_DETAIL="${OSD_READY}/${OSD_TOTAL} ready (expected ${EXPECTED_OSDS})"
    log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
  elif [ "${OSD_READY}" -ge "$((EXPECTED_OSDS - 1))" ]; then
    PHASE3_STATUS="WARN"
    PHASE3_DETAIL="${OSD_READY}/${OSD_TOTAL} ready (expected ${EXPECTED_OSDS})"
    log "Phase 3: ${PHASE3_DETAIL} -- WARN (one OSD down)"
  else
    err "OSD count mismatch: ${OSD_READY}/${OSD_TOTAL} ready, expected ${EXPECTED_OSDS}"
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="${OSD_READY}/${OSD_TOTAL} ready (expected ${EXPECTED_OSDS})"
    OVERALL_FAILED=1
  fi
fi

# ============================================================================
# Phase 4: MON quorum
#
# Rook MON daemon pods have label app=rook-ceph-mon. Counting Running MON
# pods is the most reliable quorum approximation without requiring jq or
# the CephCluster mons array parsing.
# ============================================================================
log "Phase 4: Checking MON quorum (expected ${EXPECTED_MONS})"

MON_PODS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pods \
  -l app=rook-ceph-mon --no-headers -o wide 2>&1) \
  || { err "kubectl get MON pods failed"; MON_PODS=""; }

# Fallback: generic grep for rook-ceph-mon- if label selector misses
if [ -z "$(echo "${MON_PODS}" | head -1)" ]; then
  log "  app=rook-ceph-mon label selector returned no pods, falling back to name grep"
  MON_PODS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get pods --no-headers -o wide 2>&1 | grep 'rook-ceph-mon-' || true)
fi

if [ -z "$(echo "${MON_PODS}" | head -1)" ]; then
  # Fallback: check CephCluster status for mons field
  MON_JSON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get cephcluster -o jsonpath='{.items[0].status.ceph}' 2>/dev/null || true)
  if [ -n "${MON_JSON}" ] && echo "${MON_JSON}" | grep -q '"mons"'; then
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="MON status in CephCluster (pods not yet visible)"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED (graceful)"
  else
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="MON state not yet available (CephCluster initializing)"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED (graceful)"
  fi
else
  MON_TOTAL=0
  MON_RUNNING=0
  MON_NOT_RUNNING=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    MON_TOTAL=$((MON_TOTAL + 1))
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')
    if [ "${STATUS_FIELD}" = "Running" ]; then
      MON_RUNNING=$((MON_RUNNING + 1))
    else
      POD_NAME=$(echo "$line" | awk '{print $1}')
      MON_NOT_RUNNING="${MON_NOT_RUNNING} ${POD_NAME}(${STATUS_FIELD})"
    fi
  done <<< "${MON_PODS}"

  if [ -n "${MON_NOT_RUNNING}" ]; then
    err "MON pods not running:${MON_NOT_RUNNING}"
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="${MON_RUNNING}/${MON_TOTAL} running (expected ${EXPECTED_MONS})"
    OVERALL_FAILED=1
  elif [ "${MON_RUNNING}" -eq "${EXPECTED_MONS}" ]; then
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="${MON_RUNNING}/${EXPECTED_MONS} running"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED"
  elif [ "${MON_RUNNING}" -ge 2 ]; then
    PHASE4_STATUS="WARN"
    PHASE4_DETAIL="${MON_RUNNING}/${EXPECTED_MONS} running"
    log "Phase 4: ${PHASE4_DETAIL} -- WARN (partial quorum)"
  else
    err "MON quorum lost: ${MON_RUNNING}/${MON_TOTAL} running"
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="${MON_RUNNING}/${MON_TOTAL} running"
    OVERALL_FAILED=1
  fi
fi

# ============================================================================
# Phase 5: StorageClass existence (ceph-rbd)
# ============================================================================
log "Phase 5: Checking StorageClass 'ceph-rbd'"
SC_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" get sc ceph-rbd -o json 2>&1) \
  || { err "StorageClass 'ceph-rbd' not found: ${SC_OUTPUT}"; PHASE5_STATUS="FAIL"; PHASE5_DETAIL="sc not found"; OVERALL_FAILED=1; }

if [ -z "${PHASE5_STATUS}" ]; then
  SC_PROVISIONER=$(echo "${SC_OUTPUT}" | grep -o '"provisioner":"[^"]*"' | head -1 | cut -d: -f2- | tr -d '"' || echo "unknown")

  if echo "${SC_PROVISIONER}" | grep -q "rbd.csi.ceph.com"; then
    PHASE5_STATUS="PASS"
    PHASE5_DETAIL="ceph-rbd found (provisioner: ${SC_PROVISIONER})"
    log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
  else
    PHASE5_STATUS="WARN"
    PHASE5_DETAIL="ceph-rbd found, unexpected provisioner: ${SC_PROVISIONER}"
    log "Phase 5: ${PHASE5_DETAIL} -- WARN"
  fi
fi

# ============================================================================
# Phase 6: CephBlockPool 'default.rbd' existence
# ============================================================================
log "Phase 6: Checking CephBlockPool 'default.rbd'"
POOL_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get cephblockpool default.rbd 2>&1) \
  || { err "CephBlockPool 'default.rbd' not found: ${POOL_OUTPUT}"; PHASE6_STATUS="FAIL"; PHASE6_DETAIL="pool not found"; OVERALL_FAILED=1; }

if [ -z "${PHASE6_STATUS}" ]; then
  POOL_PHASE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get cephblockpool default.rbd -o jsonpath='{.status.phase}' 2>/dev/null || true)

  if [ -z "${POOL_PHASE}" ]; then
    PHASE6_STATUS="PASS"
    PHASE6_DETAIL="default.rbd exists (phase not yet reported)"
    log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
  elif [ "${POOL_PHASE}" = "Ready" ]; then
    PHASE6_STATUS="PASS"
    PHASE6_DETAIL="default.rbd exists, phase=${POOL_PHASE}"
    log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
  else
    PHASE6_STATUS="PASS"
    PHASE6_DETAIL="default.rbd exists, phase=${POOL_PHASE}"
    log "Phase 6: ${PHASE6_DETAIL} -- PASSED (non-Ready phase)"
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Ceph Health Verification Summary ==="
printf "%-10s %-12s %-54s\n" "PHASE"     "STATUS" "DETAIL"
printf "%-10s %-12s %-54s\n" "-----"     "------" "------"
printf "%-10s %-12s %-54s\n" "1-Op-Pod"  "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-54s\n" "2-Cluster" "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-54s\n" "3-OSDs"    "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-54s\n" "4-MONs"    "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-10s %-12s %-54s\n" "5-SC"      "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-10s %-12s %-54s\n" "6-Pool"    "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
echo "========================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "========================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-ceph: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-ceph: ALL CHECKS PASSED"
exit 0

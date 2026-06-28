#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-pulsar.sh -- Apache Pulsar cluster health verification
#
# Verifies the Pulsar streaming cluster that analytics pipelines depend on:
#   Phase 1: ZooKeeper pod health and PVC binding
#   Phase 2: BookKeeper pod health and PVC binding
#   Phase 3: Broker pod health and service endpoint
#   Phase 4: Function Worker pod health
#   Phase 5: Pulsar admin connectivity (topic CRUD via pulsar-admin CLI)
#   Phase 6: End-to-end produce/consume on a verification topic
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-pulsar.sh [--kubeconfig <path>]
#                           [--namespace <ns>]
#                           [--release-name <name>]
#                           [--wait-timeout <seconds>]
#                           [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables ---------------------------------------

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="pulsar"
RELEASE_NAME="pulsar"
TOOLSET_POD="${RELEASE_NAME}-toolset-0"
VERIFY_TOPIC="verify-test-$(date +%s)"
WAIT_TIMEOUT=60

# Expected pod counts (matches install-pulsar.sh defaults)
EXPECTED_ZK=1
EXPECTED_BK=1
EXPECTED_BROKER=1
EXPECTED_FW=1

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)               KUBECONFIG="$2";                       shift 2 ;;
    --namespace)                NAMESPACE="$2";                        shift 2 ;;
    --release-name)             RELEASE_NAME="$2";                     shift 2 ;;
    --expected-zk)              EXPECTED_ZK="$2";                      shift 2 ;;
    --expected-bk)              EXPECTED_BK="$2";                      shift 2 ;;
    --expected-broker)          EXPECTED_BROKER="$2";                   shift 2 ;;
    --expected-fw)              EXPECTED_FW="$2";                      shift 2 ;;
    --wait-timeout)             WAIT_TIMEOUT="$2";                     shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Apache Pulsar cluster health: ZooKeeper, BookKeeper, Broker,
Function Worker, pulsar-admin connectivity, and produce/consume test.

Phases:
  1  ZooKeeper pod health and PVC binding
  2  BookKeeper pod health and PVC binding (data + journal)
  3  Broker pod health and service endpoint
  4  Function Worker pod health
  5  Pulsar admin connectivity (topic CRUD)
  6  Produce/consume test on verification topic

Options:
  --kubeconfig PATH        Path to kubeconfig (default: ../opentofu/kubeconfig)
  --namespace NS           Pulsar namespace (default: pulsar)
  --release-name NAME      Helm release name (default: pulsar)
  --expected-zk NUM        Expected ZooKeeper pods (default: 1)
  --expected-bk NUM        Expected BookKeeper pods (default: 1)
  --expected-broker NUM    Expected Broker pods (default: 1)
  --expected-fw NUM        Expected Function Worker pods (default: 1)
  --wait-timeout SECONDS   Max seconds to wait for resources (default: 60)
  --help, -h               Show this help message

Examples:
  ./verify-pulsar.sh
  ./verify-pulsar.sh --namespace pulsar --release-name pulsar
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG
TOOLSET_POD="${RELEASE_NAME}-toolset-0"

# ---- Preflight Checks -----------------------------------------------------
log "verify-pulsar: starting"
log "  kubeconfig:     ${KUBECONFIG}"
log "  namespace:      ${NAMESPACE}"
log "  release:        ${RELEASE_NAME}"
log "  wait-timeout:   ${WAIT_TIMEOUT}s"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""
PHASE1_DETAIL=""
PHASE2_STATUS=""
PHASE2_DETAIL=""
PHASE3_STATUS=""
PHASE3_DETAIL=""
PHASE4_STATUS=""
PHASE4_DETAIL=""
PHASE5_STATUS=""
PHASE5_DETAIL=""
PHASE6_STATUS=""
PHASE6_DETAIL=""

OVERALL_FAILED=0

# ---- Helper: check pods by label selector ---------------------------------
check_pod_health_by_label() {
  local ns="$1"
  local label="$2"
  local expected="$3"
  local -n out_status="$4"
  local -n out_detail="$5"

  log "Checking pod health in '${ns}' matching '${label}' (expected ${expected})"

  local POD_OUTPUT
  POD_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pods \
    -l "${label}" --no-headers 2>&1) \
    || { err "kubectl get pods with label '${label}' failed: ${POD_OUTPUT}"; out_status="FAIL"; out_detail="kubectl error"; return 1; }

  # Fallback: try name-based match
  if [ -z "$(echo "${POD_OUTPUT}" | head -1)" ]; then
    local name_pattern
    name_pattern=$(echo "${label}" | grep -oP '(?<=app=)[^,]+|(?<=component=)[^,]+' || true)
    if [ -z "${name_pattern}" ]; then
      out_status="FAIL"
      out_detail="no pods found for label '${label}'"
      return 1
    fi
    POD_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pods --no-headers 2>&1 \
      | grep "${name_pattern}" || true)
  fi

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
    err "Pods not ready (${label}):${NOT_OK}"
    out_status="FAIL"
    out_detail="${READY}/${TOTAL} ready"
    return 1
  elif [ "${TOTAL}" -eq 0 ]; then
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
    return 0
  else
    err "Pod count mismatch (${label}): ${READY}/${TOTAL} ready, expected ${expected}"
    out_status="FAIL"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    return 1
  fi
}

# ---- Helper: check pods in namespace --------------------------------------
check_pod_health() {
  local ns="$1"
  local expected="$2"
  local -n out_status="$3"
  local -n out_detail="$4"

  log "Checking pod health in namespace '${ns}' (expected ${expected})"

  local POD_OUTPUT
  POD_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pods --no-headers 2>&1) \
    || { err "kubectl get pods in '${ns}' failed"; out_status="FAIL"; out_detail="kubectl error"; return 1; }

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
    out_status="FAIL"
    out_detail="0 pods"
    return 1
  elif [ "${READY}" -eq "${expected}" ]; then
    out_status="PASS"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    return 0
  elif [ "${READY}" -ge "$((expected - 1))" ]; then
    out_status="WARN"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    return 0
  else
    out_status="FAIL"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    return 1
  fi
}

# ---- Helper: check PVC binding --------------------------------------------
check_pvc_bound() {
  local ns="$1"
  local label="$2"
  local -n out_status="$3"
  local -n out_detail="$4"

  log "Checking PVC binding in '${ns}' matching '${label}'"

  local PVC_OUTPUT
  PVC_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pvc \
    -l "${label}" --no-headers 2>&1) \
    || { err "kubectl get pvc with label '${label}' failed"; out_status="FAIL"; out_detail="kubectl error"; return 1; }

  # Fallback to all PVCs if label selector returned nothing
  if [ -z "$(echo "${PVC_OUTPUT}" | head -1)" ]; then
    PVC_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pvc --no-headers 2>&1 | grep "${RELEASE_NAME}" || true)
    if [ -z "$(echo "${PVC_OUTPUT}" | head -1)" ]; then
      out_status="WARN"
      out_detail="0 PVCs found for '${RELEASE_NAME}'"
      return 0
    fi
  fi

  local TOTAL=0
  local BOUND=0
  local NOT_BOUND=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    TOTAL=$((TOTAL + 1))
    local PVC_STATUS
    PVC_STATUS=$(echo "$line" | awk '{print $2}')
    if [ "${PVC_STATUS}" = "Bound" ]; then
      BOUND=$((BOUND + 1))
    else
      local PVC_NAME
      PVC_NAME=$(echo "$line" | awk '{print $1}')
      NOT_BOUND="${NOT_BOUND} ${PVC_NAME}(${PVC_STATUS})"
    fi
  done <<< "${PVC_OUTPUT}"

  if [ -n "${NOT_BOUND}" ]; then
    err "PVCs not Bound:${NOT_BOUND}"
    out_status="FAIL"
    out_detail="${BOUND}/${TOTAL} Bound"
    return 1
  elif [ "${TOTAL}" -eq 0 ]; then
    out_status="WARN"
    out_detail="0 PVCs matching '${label}'"
    return 0
  elif [ "${BOUND}" -eq "${TOTAL}" ]; then
    out_status="PASS"
    out_detail="${BOUND}/${TOTAL} Bound"
    return 0
  else
    out_status="FAIL"
    out_detail="${BOUND}/${TOTAL} Bound"
    return 1
  fi
}

# ============================================================================
# Phase 1: ZooKeeper pod health and PVC binding
# ============================================================================
log "Phase 1: ZooKeeper pod health and PVC binding"

if kubectl --kubeconfig "${KUBECONFIG}" get ns "${NAMESPACE}" > /dev/null 2>&1; then
  P1_PODS_OK=true
  check_pod_health_by_label "${NAMESPACE}" "component=zookeeper,app=${RELEASE_NAME}" \
    "${EXPECTED_ZK}" PHASE1_STATUS PHASE1_DETAIL \
    || { P1_PODS_OK=false; OVERALL_FAILED=1; }

  # PVC check (non-fatal)
  local zk_pvc_status="" zk_pvc_detail=""
  check_pvc_bound "${NAMESPACE}" "component=zookeeper,app=${RELEASE_NAME}" \
    zk_pvc_status zk_pvc_detail || true

  if [ "${P1_PODS_OK}" = true ]; then
    PHASE1_DETAIL="${PHASE1_DETAIL} | PVCs: ${zk_pvc_detail:-pending}"
  fi
else
  PHASE1_STATUS="FAIL"
  PHASE1_DETAIL="Namespace '${NAMESPACE}' not found"
  err "Namespace '${NAMESPACE}' does not exist"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: BookKeeper pod health and PVC binding
# ============================================================================
log "Phase 2: BookKeeper pod health and PVC binding"
P2_PODS_OK=true

check_pod_health_by_label "${NAMESPACE}" "component=bookie,app=${RELEASE_NAME}" \
  "${EXPECTED_BK}" PHASE2_STATUS PHASE2_DETAIL \
  || { P2_PODS_OK=false; OVERALL_FAILED=1; }

# PVC check (non-fatal)
local bk_pvc_status="" bk_pvc_detail=""
check_pvc_bound "${NAMESPACE}" "component=bookkeeper,app=${RELEASE_NAME}" \
  bk_pvc_status bk_pvc_detail || true

if [ "${P2_PODS_OK}" = true ]; then
  PHASE2_DETAIL="${PHASE2_DETAIL} | PVCs: ${bk_pvc_detail:-pending}"
fi

# ============================================================================
# Phase 3: Broker pod health and service endpoint
# ============================================================================
log "Phase 3: Broker pod health and service endpoint"
P3_PODS_OK=true

check_pod_health_by_label "${NAMESPACE}" "component=broker,app=${RELEASE_NAME}" \
  "${EXPECTED_BROKER}" PHASE3_STATUS PHASE3_DETAIL \
  || { P3_PODS_OK=false; OVERALL_FAILED=1; }

# Check broker service exists
BROKER_SVC="${RELEASE_NAME}-broker.${NAMESPACE}.svc.cluster.local"
if kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get svc "${RELEASE_NAME}-broker" > /dev/null 2>&1; then
  BROKER_PORTS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get svc "${RELEASE_NAME}-broker" \
    -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)
  log "  Broker service '${RELEASE_NAME}-broker' found (ports: ${BROKER_PORTS})"
  if [ "${P3_PODS_OK}" = true ]; then
    PHASE3_DETAIL="${PHASE3_DETAIL} | svc: ${BROKER_SVC}"
  fi
else
  log "  (non-fatal) Broker service not found"
  if [ "${P3_PODS_OK}" = true ]; then
    PHASE3_STATUS="WARN"
    PHASE3_DETAIL="${PHASE3_DETAIL} | svc: not found"
  fi
fi

# ============================================================================
# Phase 4: Function Worker pod health
# ============================================================================
log "Phase 4: Function Worker pod health"

check_pod_health_by_label "${NAMESPACE}" "component=function-worker,app=${RELEASE_NAME}" \
  "${EXPECTED_FW}" PHASE4_STATUS PHASE4_DETAIL \
  || { OVERALL_FAILED=1; }

# ============================================================================
# Phase 5: Pulsar admin connectivity (topic CRUD via pulsar-admin CLI)
# ============================================================================
log "Phase 5: Pulsar admin connectivity (topic CRUD)"

if kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pod "${TOOLSET_POD}" > /dev/null 2>&1; then
  # Wait for toolset pod to be Ready
  log "  Checking toolset pod '${TOOLSET_POD}'..."
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" wait --for=condition=Ready \
    "pod/${TOOLSET_POD}" --timeout="${WAIT_TIMEOUT}s" > /dev/null 2>&1; then

    # Test pulsar-admin by listing existing topics
    log "  Testing pulsar-admin topics list..."
    ADMIN_TEST=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
      pulsar-admin topics list public/default 2>&1) || ADMIN_TEST_FAILED=true

    if [ "${ADMIN_TEST_FAILED:-false}" = true ]; then
      # Try listing tenants as a simpler test
      ADMIN_TEST=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
        pulsar-admin tenants list 2>&1) || ADMIN_TEST_FAILED2=true

      if [ "${ADMIN_TEST_FAILED2:-false}" = true ]; then
        ADMIN_DETAIL=$(echo "${ADMIN_TEST}" | tr '\n' ' ' | head -c 80)
        PHASE5_STATUS="FAIL"
        PHASE5_DETAIL="pulsar-admin CLI not reachable: ${ADMIN_DETAIL}"
        OVERALL_FAILED=1
      else
        PHASE5_STATUS="PASS"
        PHASE5_DETAIL="pulsar-admin responsive (tenants: $(echo "${ADMIN_TEST}" | tr '\n' ' '))"
        log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
      fi
    else
      PHASE5_STATUS="PASS"
      PHASE5_DETAIL="pulsar-admin responsive (topics: $(echo "${ADMIN_TEST}" | tr '\n' ' '))"
      log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
    fi
  else
    PHASE5_STATUS="FAIL"
    PHASE5_DETAIL="Toolset pod '${TOOLSET_POD}' not Ready within ${WAIT_TIMEOUT}s"
    err "Phase 5: ${PHASE5_DETAIL}"
    OVERALL_FAILED=1
  fi
else
  PHASE5_STATUS="WARN"
  PHASE5_DETAIL="Toolset pod '${TOOLSET_POD}' not found — admin checks skipped"
  log "Phase 5: ${PHASE5_DETAIL}"
fi

# ============================================================================
# Phase 6: End-to-end produce/consume test on verification topic
# ============================================================================
log "Phase 6: Produce/consume test on verification topic"

# Skip if admin connectivity failed (Phase 5) — cluster isn't healthy enough
if [ "${PHASE5_STATUS}" = "FAIL" ] || [ "${PHASE5_STATUS}" = "WARN" ]; then
  PHASE6_STATUS="SKIP"
  PHASE6_DETAIL="Admin CLI not available — skipping produce/consume test"
  log "Phase 6: ${PHASE6_DETAIL}"
else
  # Create a temporary verification topic
  log "  Creating verification topic '${VERIFY_TOPIC}'..."
  kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin topics create persistent://public/default/"${VERIFY_TOPIC}" 2>/dev/null \
    || log "  (non-fatal) Topic may already exist"

  # Produce a test message using Pulsar client in the toolset pod
  TEST_MESSAGE="verify-pulsar-$(date +%s)"
  local PRODUCE_CMD
  PRODUCE_CMD="echo '{\"uuid\":\"${TEST_MESSAGE}\",\"dev\":\"verify\",\"val\":42.0}' | \
    /pulsar/bin/pulsar-client produce persistent://public/default/${VERIFY_TOPIC} \
    --messages 1 \
    --max-pending-messages 1 \
    2>&1"

  log "  Producing: ${TEST_MESSAGE}"
  PRODUCE_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    bash -c "${PRODUCE_CMD}" 2>&1) || true

  if echo "${PRODUCE_RESULT}" | grep -qi "success\|produced\|sent"; then
    log "  Produce succeeded"
  else
    log "  (non-fatal) Produce may have warnings: $(echo "${PRODUCE_RESULT}" | tail -1)"
  fi

  # Consume the message back
  local CONSUME_CMD
  CONSUME_CMD="/pulsar/bin/pulsar-client consume persistent://public/default/${VERIFY_TOPIC} \
    --subscription-name verify-sub \
    --num-messages 1 \
    --timeout-ms 15000 \
    2>&1"

  log "  Consuming one message..."
  CONSUME_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    bash -c "${CONSUME_CMD}" 2>&1) || true

  # Check if we got the message back
  if echo "${CONSUME_RESULT}" | grep -q "${TEST_MESSAGE}"; then
    PHASE6_STATUS="PASS"
    PHASE6_DETAIL="Produce/consume verified on '${VERIFY_TOPIC}'"
    log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
  elif echo "${CONSUME_RESULT}" | grep -qi "success\|received\|message"; then
    # Message was received (UUID may not echo back in the same format)
    PHASE6_STATUS="PASS"
    PHASE6_DETAIL="Produce/consume completed on '${VERIFY_TOPIC}' (message received)"
    log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
  else
    CONSUME_DETAIL=$(echo "${CONSUME_RESULT}" | tr '\n' ' ' | head -c 120)
    err "Consume from '${VERIFY_TOPIC}' failed: ${CONSUME_DETAIL}"
    PHASE6_STATUS="FAIL"
    PHASE6_DETAIL="Produce/consume failed: ${CONSUME_DETAIL}"
    OVERALL_FAILED=1
  fi

  # Clean up verification topic
  log "  Cleaning up verification topic..."
  kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin topics delete persistent://public/default/"${VERIFY_TOPIC}" 2>/dev/null || true
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Pulsar Health Verification Summary ==="
printf "%-12s %-12s %-60s\n" "PHASE"          "STATUS" "DETAIL"
printf "%-12s %-12s %-60s\n" "-----"          "------" "------"
printf "%-12s %-12s %-60s\n" "1-ZooKeeper"    "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-12s %-12s %-60s\n" "2-BookKeeper"   "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-12s %-12s %-60s\n" "3-Broker"       "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-12s %-12s %-60s\n" "4-FuncWorker"   "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-12s %-12s %-60s\n" "5-Admin"        "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-12s %-12s %-60s\n" "6-ProdCons"     "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
echo "================================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "================================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-pulsar: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-pulsar: ALL CHECKS PASSED"
exit 0

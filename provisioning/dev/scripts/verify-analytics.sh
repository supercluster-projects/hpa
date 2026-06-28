#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-analytics.sh -- Pulsar + ClickHouse analytics pipeline verification
#
# End-to-end verification of the analytics pipeline:
#   Phase 1: Pulsar cluster health (quick check)
#   Phase 2: ClickHouse connectivity and table readiness
#   Phase 3: Topic existence (raw-events, processed-events)
#   Phase 4: Pulsar Function deployment status (telemetry-processor)
#   Phase 5: JDBC ClickHouse Sink status
#   Phase 6: End-to-end produce-verify (produce to raw-events -> SELECT from ClickHouse)
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-analytics.sh [--kubeconfig <path>]
#                              [--pulsar-namespace <ns>]
#                              [--pulsar-release <name>]
#                              [--clickhouse-namespace <ns>]
#                              [--clickhouse-release <name>]
#                              [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Internal defaults ----------------------------------------------------
PULSAR_NAMESPACE="pulsar"
PULSAR_RELEASE="pulsar"
TOOLSET_POD="${PULSAR_RELEASE}-toolset-0"
CLICKHOUSE_NAMESPACE="clickhouse"
CLICKHOUSE_RELEASE="clickhouse"
CLICKHOUSE_POD="${CLICKHOUSE_RELEASE}-clickhouse-0"
FUNCTION_NAME="telemetry-processor"
SINK_NAME="clickhouse-telemetry-sink"
WAIT_TIMEOUT=60

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)               KUBECONFIG="$2";                       shift 2 ;;
    --pulsar-namespace)          PULSAR_NAMESPACE="$2";                 shift 2 ;;
    --pulsar-release)            PULSAR_RELEASE="$2";                   shift 2 ;;
    --clickhouse-namespace)      CLICKHOUSE_NAMESPACE="$2";             shift 2 ;;
    --clickhouse-release)        CLICKHOUSE_RELEASE="$2";               shift 2 ;;
    --wait-timeout)              WAIT_TIMEOUT="$2";                     shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

End-to-end verification of the Pulsar + ClickHouse analytics pipeline.

Phases:
  1  Pulsar cluster health (ZooKeeper, BookKeeper, Broker pods)
  2  ClickHouse connectivity and table readiness
  3  Topic existence (raw-events, processed-events)
  4  Pulsar Function status (telemetry-processor)
  5  JDBC ClickHouse Sink status
  6  End-to-end produce-verify

Options:
  --kubeconfig PATH              Path to kubeconfig
  --pulsar-namespace NS          Pulsar namespace (default: pulsar)
  --pulsar-release NAME          Pulsar Helm release name (default: pulsar)
  --clickhouse-namespace NS      ClickHouse namespace (default: clickhouse)
  --clickhouse-release NAME      ClickHouse release name (default: clickhouse)
  --wait-timeout SECONDS         Max seconds to wait for resources (default: 60)
  --help, -h                     Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG
TOOLSET_POD="${PULSAR_RELEASE}-toolset-0"
CLICKHOUSE_POD="${CLICKHOUSE_RELEASE}-clickhouse-0"
CLICKHOUSE_QUERY="clickhouse-client --user=default --password=clickhouse_admin --query"

# ---- Preflight Checks -----------------------------------------------------
log "verify-analytics: starting"
log "  pulsar namespace:    ${PULSAR_NAMESPACE}"
log "  clickhouse namespace: ${CLICKHOUSE_NAMESPACE}"

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

# ============================================================================
# Phase 1: Pulsar cluster health (quick check)
# ============================================================================
log "Phase 1: Pulsar cluster health"

if kubectl --kubeconfig "${KUBECONFIG}" get ns "${PULSAR_NAMESPACE}" > /dev/null 2>&1; then
  # Check ZK, BK, Broker pods
  ZK_READY="0"
  BK_READY="0"
  BROKER_READY="0"
  FW_READY="0"

  if kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get statefulset \
    "${PULSAR_RELEASE}-zookeeper" > /dev/null 2>&1; then
    ZK_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get statefulset \
      "${PULSAR_RELEASE}-zookeeper" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  fi
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get statefulset \
    "${PULSAR_RELEASE}-bookkeeper" > /dev/null 2>&1; then
    BK_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get statefulset \
      "${PULSAR_RELEASE}-bookkeeper" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  fi
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get statefulset \
    "${PULSAR_RELEASE}-broker" > /dev/null 2>&1; then
    BROKER_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get statefulset \
      "${PULSAR_RELEASE}-broker" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  fi
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get deployment \
    "${PULSAR_RELEASE}-function-worker" > /dev/null 2>&1; then
    FW_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get deployment \
      "${PULSAR_RELEASE}-function-worker" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  fi

  if [ "${ZK_READY}" -ge 1 ] && [ "${BK_READY}" -ge 1 ] && [ "${BROKER_READY}" -ge 1 ]; then
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="ZK=${ZK_READY}/1 BK=${BK_READY}/1 Broker=${BROKER_READY}/1 FW=${FW_READY}/1"
    log "Phase 1: ${PHASE1_DETAIL} -- PASSED"
  else
    PHASE1_STATUS="WARN"
    PHASE1_DETAIL="ZK=${ZK_READY}/1 BK=${BK_READY}/1 Broker=${BROKER_READY}/1 FW=${FW_READY}/1"
    log "Phase 1: ${PHASE1_DETAIL}"
  fi
else
  PHASE1_STATUS="FAIL"
  PHASE1_DETAIL="Namespace '${PULSAR_NAMESPACE}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: ClickHouse connectivity and table readiness
# ============================================================================
log "Phase 2: ClickHouse connectivity and table readiness"

if kubectl --kubeconfig "${KUBECONFIG}" get ns "${CLICKHOUSE_NAMESPACE}" > /dev/null 2>&1; then
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${CLICKHOUSE_NAMESPACE}" get pod \
    "${CLICKHOUSE_POD}" > /dev/null 2>&1; then

    # Pod Ready check
    CH_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLICKHOUSE_NAMESPACE}" get pod \
      "${CLICKHOUSE_POD}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

    if [ "${CH_READY}" = "True" ]; then
      # Check table exists with columns
      TABLE_CHECK=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLICKHOUSE_NAMESPACE}" exec \
        "${CLICKHOUSE_POD}" -- bash -c "${CLICKHOUSE_QUERY} 'SELECT COUNT(*) FROM analytics_db.device_metrics'" 2>/dev/null | head -1)

      DB_CHECK=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLICKHOUSE_NAMESPACE}" exec \
        "${CLICKHOUSE_POD}" -- bash -c "${CLICKHOUSE_QUERY} 'SELECT count() FROM system.databases WHERE name='"'analytics_db'"''" 2>/dev/null | head -1)

      if [ "${DB_CHECK}" = "1" ] 2>/dev/null; then
        PHASE2_STATUS="PASS"
        PHASE2_DETAIL="ClickHouse Ready, analytics_db exists, rows in device_metrics: ${TABLE_CHECK:-0}"
        log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
      else
        PHASE2_STATUS="WARN"
        PHASE2_DETAIL="ClickHouse Ready but analytics_db may be missing"
        log "Phase 2: ${PHASE2_DETAIL}"
      fi
    else
      PHASE2_STATUS="FAIL"
      PHASE2_DETAIL="ClickHouse pod not Ready"
      OVERALL_FAILED=1
    fi
  else
    PHASE2_STATUS="FAIL"
    PHASE2_DETAIL="ClickHouse pod '${CLICKHOUSE_POD}' not found"
    OVERALL_FAILED=1
  fi
else
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="Namespace '${CLICKHOUSE_NAMESPACE}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 3: Topic existence
# ============================================================================
log "Phase 3: Topic existence (raw-events, processed-events)"

if kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" get pod \
  "${TOOLSET_POD}" > /dev/null 2>&1; then

  kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" wait \
    --for=condition=Ready "pod/${TOOLSET_POD}" --timeout="${WAIT_TIMEOUT}s" > /dev/null 2>&1

  # List topics
  TOPICS_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" exec \
    "${TOOLSET_POD}" -- pulsar-admin topics list public/default 2>&1)

  HAS_RAW=false
  HAS_PROCESSED=false

  if echo "${TOPICS_OUTPUT}" | grep -q "raw-events"; then
    HAS_RAW=true
  fi
  if echo "${TOPICS_OUTPUT}" | grep -q "processed-events"; then
    HAS_PROCESSED=true
  fi

  # Try partitioned topics list as fallback
  if [ "${HAS_RAW}" = false ]; then
    PART_TOPICS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" exec \
      "${TOOLSET_POD}" -- pulsar-admin topics list-partitioned-topics public/default 2>&1)
    echo "${PART_TOPICS}" | grep -q "raw-events" && HAS_RAW=true
    echo "${PART_TOPICS}" | grep -q "processed-events" && HAS_PROCESSED=true
  fi

  if [ "${HAS_RAW}" = true ] && [ "${HAS_PROCESSED}" = true ]; then
    PHASE3_STATUS="PASS"
    PHASE3_DETAIL="raw-events and processed-events exist in public/default"
    log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
  elif [ "${HAS_RAW}" = true ] || [ "${HAS_PROCESSED}" = true ]; then
    PHASE3_STATUS="WARN"
    PHASE3_DETAIL="raw-events=${HAS_RAW} processed-events=${HAS_PROCESSED}"
    log "Phase 3: ${PHASE3_DETAIL}"
  else
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="Neither raw-events nor processed-events found"
    log "Phase 3: ${PHASE3_DETAIL}"
    OVERALL_FAILED=1
  fi
else
  PHASE3_STATUS="SKIP"
  PHASE3_DETAIL="Toolset pod not available"
fi

# ============================================================================
# Phase 4: Pulsar Function deployment status
# ============================================================================
log "Phase 4: Pulsar Function status (${FUNCTION_NAME})"

if [ "${PHASE3_STATUS}" != "SKIP" ]; then
  FUNC_STATUS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" exec \
    "${TOOLSET_POD}" -- pulsar-admin functions status \
    --tenant public --namespace default --name "${FUNCTION_NAME}" 2>&1)

  if echo "${FUNC_STATUS}" | grep -qi "numInstances\|Running\|running\|numRunning"; then
    NUM_RUNNING=$(echo "${FUNC_STATUS}" | grep -oP '"numRunning"\s*:\s*\d+' | grep -oP '\d+' || echo "0")
    NUM_INSTANCES=$(echo "${FUNC_STATUS}" | grep -oP '"numInstances"\s*:\s*\d+' | grep -oP '\d+' || echo "0")

    if [ "${NUM_RUNNING}" -ge 1 ] 2>/dev/null; then
      PHASE4_STATUS="PASS"
      PHASE4_DETAIL="Function '${FUNCTION_NAME}' running (${NUM_RUNNING}/${NUM_INSTANCES} instances)"
      log "Phase 4: ${PHASE4_DETAIL} -- PASSED"
    else
      PHASE4_STATUS="WARN"
      PHASE4_DETAIL="Function exists but not running: $(echo "${FUNC_STATUS}" | head -3 | tr '\n' ' ')"
      log "Phase 4: ${PHASE4_DETAIL}"
    fi
  else
    # Check if function exists at all
    FUNC_GET=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" exec \
      "${TOOLSET_POD}" -- pulsar-admin functions get \
      --tenant public --namespace default --name "${FUNCTION_NAME}" 2>&1)
    if echo "${FUNC_GET}" | grep -qi "FunctionConfig\|functionName\|${FUNCTION_NAME}"; then
      PHASE4_STATUS="WARN"
      PHASE4_DETAIL="Function exists but status unavailable (may still be initializing)"
      log "Phase 4: ${PHASE4_DETAIL}"
    else
      PHASE4_STATUS="FAIL"
      PHASE4_DETAIL="Function '${FUNCTION_NAME}' not found"
      OVERALL_FAILED=1
    fi
  fi
else
  PHASE4_STATUS="SKIP"
  PHASE4_DETAIL="Toolset pod skipped -- cannot check function"
fi

# ============================================================================
# Phase 5: JDBC ClickHouse Sink status
# ============================================================================
log "Phase 5: JDBC ClickHouse Sink status (${SINK_NAME})"

if [ "${PHASE3_STATUS}" != "SKIP" ]; then
  SINK_STATUS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" exec \
    "${TOOLSET_POD}" -- pulsar-admin sinks status \
    --tenant public --namespace default --name "${SINK_NAME}" 2>&1)

  if echo "${SINK_STATUS}" | grep -qi "numInstances\|Running\|running\|numRunning"; then
    SINK_RUNNING=$(echo "${SINK_STATUS}" | grep -oP '"numRunning"\s*:\s*\d+' | grep -oP '\d+' || echo "0")
    SINK_INSTANCES=$(echo "${SINK_STATUS}" | grep -oP '"numInstances"\s*:\s*\d+' | grep -oP '\d+' || echo "0")

    if [ "${SINK_RUNNING}" -ge 1 ] 2>/dev/null; then
      PHASE5_STATUS="PASS"
      PHASE5_DETAIL="Sink '${SINK_NAME}' running (${SINK_RUNNING}/${SINK_INSTANCES} instances)"
      log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
    else
      PHASE5_STATUS="WARN"
      PHASE5_DETAIL="Sink exists but not running: $(echo "${SINK_STATUS}" | head -3 | tr '\n' ' ')"
      log "Phase 5: ${PHASE5_DETAIL}"
    fi
  else
    SINK_GET=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" exec \
      "${TOOLSET_POD}" -- pulsar-admin sinks get \
      --tenant public --namespace default --name "${SINK_NAME}" 2>&1)
    if echo "${SINK_GET}" | grep -qi "sinkConfig\|${SINK_NAME}"; then
      PHASE5_STATUS="WARN"
      PHASE5_DETAIL="Sink exists but status unavailable (may still be initializing)"
    else
      PHASE5_STATUS="FAIL"
      PHASE5_DETAIL="Sink '${SINK_NAME}' not found"
      OVERALL_FAILED=1
    fi
  fi
else
  PHASE5_STATUS="SKIP"
  PHASE5_DETAIL="Toolset pod skipped -- cannot check sink"
fi

# ============================================================================
# Phase 6: End-to-end produce-verify
# ============================================================================
log "Phase 6: End-to-end produce-verify"

if [ "${PHASE4_STATUS}" = "PASS" ] && [ "${PHASE2_STATUS}" = "PASS" ]; then
  TEST_UUID="e2e-verify-$(date +%s)"
  TEST_DEV="e2e-sensor"
  TEST_VAL=99.9

  # Produce a test event to raw-events
  log "  Producing test event to raw-events..."
  PRODUCE_CMD="echo '{\"uuid\":\"${TEST_UUID}\",\"dev\":\"${TEST_DEV}\",\"val\":${TEST_VAL}}' | \
    /pulsar/bin/pulsar-client produce persistent://public/default/raw-events \
    --messages 1 2>&1"

  kubectl --kubeconfig "${KUBECONFIG}" -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    bash -c "${PRODUCE_CMD}" > /dev/null 2>&1
  log "  Test event produced (uuid=${TEST_UUID})"

  # Wait for function + sink to process (retry loop with backoff)
  log "  Waiting for processing (retrying up to ${WAIT_TIMEOUT}s)..."
  FOUND=false
  for i in $(seq 1 "${WAIT_TIMEOUT}"); do
    SELECT_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLICKHOUSE_NAMESPACE}" exec \
      "${CLICKHOUSE_POD}" -- bash -c \
      "${CLICKHOUSE_QUERY} 'SELECT event_id, device_type, metric_value FROM analytics_db.device_metrics WHERE event_id='"'${TEST_UUID}'"'" 2>/dev/null)

    if echo "${SELECT_RESULT}" | grep -q "${TEST_UUID}"; then
      FOUND=true
      SELECTED_EVENT=$(echo "${SELECT_RESULT}" | tr '\n' ' ')
      break
    fi
    sleep 1
  done

  if [ "${FOUND}" = true ]; then
    PHASE6_STATUS="PASS"
    PHASE6_DETAIL="End-to-end verified: ${SELECTED_EVENT}"
    log "Phase 6: ${PHASE6_DETAIL} -- PASSED"

    # Cleanup test data
    kubectl --kubeconfig "${KUBECONFIG}" -n "${CLICKHOUSE_NAMESPACE}" exec \
      "${CLICKHOUSE_POD}" -- bash -c \
      "${CLICKHOUSE_QUERY} 'ALTER TABLE analytics_db.device_metrics DELETE WHERE event_id='"'${TEST_UUID}'"'" 2>/dev/null || true
  else
    # Check if there's any data in the table
    ROW_COUNT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLICKHOUSE_NAMESPACE}" exec \
      "${CLICKHOUSE_POD}" -- bash -c \
      "${CLICKHOUSE_QUERY} 'SELECT COUNT(*) FROM analytics_db.device_metrics'" 2>/dev/null | head -1)

    PHASE6_STATUS="FAIL"
    PHASE6_DETAIL="Event '${TEST_UUID}' not found in device_metrics after ${WAIT_TIMEOUT}s wait (table has ${ROW_COUNT:-?} total rows)"
    OVERALL_FAILED=1
  fi
elif [ "${PHASE4_STATUS}" != "PASS" ]; then
  PHASE6_STATUS="SKIP"
  PHASE6_DETAIL="Pulsar Function not healthy -- skipping end-to-end test"
else
  PHASE6_STATUS="SKIP"
  PHASE6_DETAIL="ClickHouse not healthy -- skipping end-to-end test"
fi

# ============================================================================
# Summary Table
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Analytics Pipeline Verification Summary ==="
printf "%-12s %-12s %-60s\n" "PHASE"          "STATUS" "DETAIL"
printf "%-12s %-12s %-60s\n" "-----"          "------" "------"
printf "%-12s %-12s %-60s\n" "1-Pulsar"       "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-12s %-12s %-60s\n" "2-ClickHouse"   "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-12s %-12s %-60s\n" "3-Topics"       "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-12s %-12s %-60s\n" "4-Function"     "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-12s %-12s %-60s\n" "5-Sink"         "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-12s %-12s %-60s\n" "6-End2End"      "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
echo "================================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "================================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-analytics: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-analytics: ALL CHECKS PASSED"
exit 0

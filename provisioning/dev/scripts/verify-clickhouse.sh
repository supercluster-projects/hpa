#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-clickhouse.sh -- ClickHouse single-node health verification
#
# Verifies the ClickHouse analytical database used by the Pulsar analytics
# pipeline:
#   Phase 1: ClickHouse pod health
#   Phase 2: PVC binding status
#   Phase 3: ClickHouse connectivity (SELECT 1)
#   Phase 4: Database existence (analytics_db)
#   Phase 5: Table existence and schema (device_metrics)
#   Phase 6: Table ORDER BY key and engine verification
#   Phase 7: INSERT/SELECT round-trip test
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-clickhouse.sh [--kubeconfig <path>]
#                               [--namespace <ns>]
#                               [--release-name <name>]
#                               [--admin-user <user>]
#                               [--admin-password <pass>]
#                               [--expected-storage <size>]
#                               [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables ---------------------------------------

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="clickhouse"
RELEASE_NAME="clickhouse"
CLICKHOUSE_POD="${RELEASE_NAME}-clickhouse-0"
ADMIN_USER="default"
ADMIN_PASSWORD="clickhouse_admin"
EXPECTED_STORAGE="10Gi"
WAIT_TIMEOUT=60

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)               KUBECONFIG="$2";                       shift 2 ;;
    --namespace)                NAMESPACE="$2";                        shift 2 ;;
    --release-name)             RELEASE_NAME="$2";                     shift 2 ;;
    --admin-user)               ADMIN_USER="$2";                       shift 2 ;;
    --admin-password)           ADMIN_PASSWORD="$2";                   shift 2 ;;
    --expected-storage)         EXPECTED_STORAGE="$2";                  shift 2 ;;
    --wait-timeout)             WAIT_TIMEOUT="$2";                     shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify ClickHouse single-node analytical database health.

Phases:
  1  ClickHouse pod health (namespace: clickhouse)
  2  PVC binding check (expected: ${EXPECTED_STORAGE})
  3  ClickHouse connectivity (SELECT 1)
  4  Database existence (analytics_db)
  5  Table existence and schema (device_metrics)
  6  Table ORDER BY and engine verification
  7  INSERT/SELECT round-trip test

Options:
  --kubeconfig PATH        Path to kubeconfig (default: ../opentofu/kubeconfig)
  --namespace NS           Namespace (default: clickhouse)
  --release-name NAME      Helm release name (default: clickhouse)
  --admin-user USER        ClickHouse admin user (default: default)
  --admin-password PASS    ClickHouse admin password (default: clickhouse_admin)
  --expected-storage SIZE  Expected PVC size (default: 10Gi)
  --wait-timeout SECONDS   Max seconds to wait for resources (default: 60)
  --help, -h               Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG
CLICKHOUSE_POD="${RELEASE_NAME}-clickhouse-0"
CH_QUERY="clickhouse-client --user='${ADMIN_USER}' --password='${ADMIN_PASSWORD}' --query"

# ---- Preflight Checks -----------------------------------------------------
log "verify-clickhouse: starting"
log "  kubeconfig:      ${KUBECONFIG}"
log "  namespace:       ${NAMESPACE}"
log "  release:         ${RELEASE_NAME}"
log "  admin user:      ${ADMIN_USER}"

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
PHASE7_STATUS=""
PHASE7_DETAIL=""

OVERALL_FAILED=0

# ---- Helper: run a ClickHouse query and return the result -----------------
ch_query() {
  local query="$1"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
    bash -c "${CH_QUERY} '${query}'" 2>/dev/null || true
}

# ============================================================================
# Phase 1: ClickHouse pod health
# ============================================================================
log "Phase 1: ClickHouse pod health"

if kubectl --kubeconfig "${KUBECONFIG}" get ns "${NAMESPACE}" > /dev/null 2>&1; then
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pod "${CLICKHOUSE_POD}" > /dev/null 2>&1; then
    # Check pod is Ready
    POD_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pod "${CLICKHOUSE_POD}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

    if [ "${POD_READY}" = "True" ]; then
      PHASE1_STATUS="PASS"
      PHASE1_DETAIL="Pod '${CLICKHOUSE_POD}' Ready=True"
      log "Phase 1: ${PHASE1_DETAIL} -- PASSED"
    elif [ "${POD_READY}" = "False" ]; then
      PHASE1_STATUS="FAIL"
      PHASE1_DETAIL="Pod '${CLICKHOUSE_POD}' Ready=False"
      OVERALL_FAILED=1
    else
      PHASE1_STATUS="WARN"
      PHASE1_DETAIL="Pod '${CLICKHOUSE_POD}' status: ${POD_READY}"
    fi
  else
    # Check for any running clickhouse pod
    ALT_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pods \
      -l "app.kubernetes.io/instance=${RELEASE_NAME}" --no-headers \
      -o custom-columns=:metadata.name 2>/dev/null | head -1)
    if [ -n "${ALT_POD}" ]; then
      CLICKHOUSE_POD="${ALT_POD}"
      log "  Using discovered pod: ${CLICKHOUSE_POD}"

      ALT_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pod "${CLICKHOUSE_POD}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

      if [ "${ALT_READY}" = "True" ]; then
        PHASE1_STATUS="PASS"
        PHASE1_DETAIL="Pod '${CLICKHOUSE_POD}' Ready=True"
      else
        PHASE1_STATUS="FAIL"
        PHASE1_DETAIL="Pod '${CLICKHOUSE_POD}' Ready=${ALT_READY}"
        OVERALL_FAILED=1
      fi
    else
      PHASE1_STATUS="FAIL"
      PHASE1_DETAIL="No ClickHouse pod found in '${NAMESPACE}'"
      OVERALL_FAILED=1
    fi
  fi
else
  PHASE1_STATUS="FAIL"
  PHASE1_DETAIL="Namespace '${NAMESPACE}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: PVC binding status
# ============================================================================
log "Phase 2: PVC binding status"

PVC_LINE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pvc \
  -l "app.kubernetes.io/instance=${RELEASE_NAME}" --no-headers 2>/dev/null | head -1)

if [ -n "${PVC_LINE}" ]; then
  PVC_STATUS=$(echo "${PVC_LINE}" | awk '{print $2}')
  PVC_CAP=$(echo "${PVC_LINE}" | awk '{print $4}')

  if [ "${PVC_STATUS}" = "Bound" ]; then
    if echo "${PVC_CAP}" | grep -q "${EXPECTED_STORAGE}"; then
      PHASE2_STATUS="PASS"
      PHASE2_DETAIL="PVC Bound (${PVC_CAP})"
    else
      PHASE2_STATUS="WARN"
      PHASE2_DETAIL="PVC Bound but size ${PVC_CAP} differs from expected ${EXPECTED_STORAGE}"
    fi
    log "Phase 2: ${PHASE2_DETAIL}"
  else
    PHASE2_STATUS="WARN"
    PHASE2_DETAIL="PVC status: ${PVC_STATUS}"
    log "Phase 2: ${PHASE2_DETAIL}"
  fi
else
  # Try fallback without label
  PVC_LINE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pvc --no-headers 2>/dev/null | head -1)
  if [ -n "${PVC_LINE}" ]; then
    PVC_STATUS=$(echo "${PVC_LINE}" | awk '{print $2}')
    PHASE2_STATUS="WARN"
    PHASE2_DETAIL="PVC found (${PVC_STATUS}) but label matching may differ"
    log "Phase 2: ${PHASE2_DETAIL}"
  else
    PHASE2_STATUS="WARN"
    PHASE2_DETAIL="No PVCs found in '${NAMESPACE}'"
    log "Phase 2: ${PHASE2_DETAIL}"
  fi
fi

# ============================================================================
# Phase 3: ClickHouse connectivity (SELECT 1)
# ============================================================================
log "Phase 3: ClickHouse connectivity (SELECT 1)"

# Wait for pod to be Ready first
if [ "${PHASE1_STATUS}" != "FAIL" ]; then
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" wait --for=condition=Ready \
    "pod/${CLICKHOUSE_POD}" --timeout="${WAIT_TIMEOUT}s" > /dev/null 2>&1; then

    PING_RESULT=$(ch_query "SELECT 1" | head -1)
    if [ "${PING_RESULT}" = "1" ]; then
      PHASE3_STATUS="PASS"
      PHASE3_DETAIL="SELECT 1 = 1"
      log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
    else
      PHASE3_STATUS="FAIL"
      PHASE3_DETAIL="SELECT 1 returned: ${PING_RESULT:-empty}"
      OVERALL_FAILED=1
    fi
  else
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="Pod not Ready within ${WAIT_TIMEOUT}s"
    OVERALL_FAILED=1
  fi
else
  PHASE3_STATUS="SKIP"
  PHASE3_DETAIL="Pod not healthy -- skipping connectivity check"
fi

# ============================================================================
# Phase 4: Database existence (analytics_db)
# ============================================================================
log "Phase 4: Database existence (analytics_db)"

if [ "${PHASE3_STATUS}" = "PASS" ]; then
  DB_RESULT=$(ch_query "SHOW DATABASES" | grep analytics_db | head -1)
  if [ -n "${DB_RESULT}" ]; then
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="Database 'analytics_db' exists"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED"
  else
    ALL_DBS=$(ch_query "SHOW DATABASES" | tr '\n' ' ')
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="Database 'analytics_db' not found (databases: ${ALL_DBS})"
    OVERALL_FAILED=1
  fi
else
  PHASE4_STATUS="SKIP"
  PHASE4_DETAIL="ClickHouse not reachable -- skipping"
fi

# ============================================================================
# Phase 5: Table existence and schema (device_metrics)
# ============================================================================
log "Phase 5: Table existence and schema (device_metrics)"

if [ "${PHASE3_STATUS}" = "PASS" ]; then
  TABLE_COLUMNS=$(ch_query "
    SELECT name, type
    FROM system.columns
    WHERE database='analytics_db' AND table='device_metrics'
    ORDER BY position
  ")

  if echo "${TABLE_COLUMNS}" | grep -q "event_id"; then
    HAS_EVENT_ID=true
  else
    HAS_EVENT_ID=false
  fi
  if echo "${TABLE_COLUMNS}" | grep -q "device_type"; then
    HAS_DEVICE_TYPE=true
  else
    HAS_DEVICE_TYPE=false
  fi
  if echo "${TABLE_COLUMNS}" | grep -q "metric_value"; then
    HAS_METRIC_VALUE=true
  else
    HAS_METRIC_VALUE=false
  fi
  if echo "${TABLE_COLUMNS}" | grep -q "processed_timestamp"; then
    HAS_TIMESTAMP=true
  else
    HAS_TIMESTAMP=false
  fi

  if [ "${HAS_EVENT_ID}" = true ] && [ "${HAS_DEVICE_TYPE}" = true ] \
     && [ "${HAS_METRIC_VALUE}" = true ] && [ "${HAS_TIMESTAMP}" = true ]; then
    PHASE5_STATUS="PASS"
    PHASE5_DETAIL="Table 'device_metrics' with all 4 columns (event_id, device_type, metric_value, processed_timestamp)"
    log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
  elif [ "${HAS_EVENT_ID}" = false ] && [ "${HAS_DEVICE_TYPE}" = false ] \
       && [ "${HAS_METRIC_VALUE}" = false ] && [ "${HAS_TIMESTAMP}" = false ]; then
    PHASE5_STATUS="FAIL"
    PHASE5_DETAIL="Table 'device_metrics' not found in 'analytics_db'"
    OVERALL_FAILED=1
  else
    MISSING=""
    [ "${HAS_EVENT_ID}" = false ] && MISSING="${MISSING} event_id"
    [ "${HAS_DEVICE_TYPE}" = false ] && MISSING="${MISSING} device_type"
    [ "${HAS_METRIC_VALUE}" = false ] && MISSING="${MISSING} metric_value"
    [ "${HAS_TIMESTAMP}" = false ] && MISSING="${MISSING} processed_timestamp"
    PHASE5_STATUS="WARN"
    PHASE5_DETAIL="Table exists but missing columns:${MISSING}"
    log "Phase 5: ${PHASE5_DETAIL}"
  fi
else
  PHASE5_STATUS="SKIP"
  PHASE5_DETAIL="ClickHouse not reachable -- skipping"
fi

# ============================================================================
# Phase 6: Table engine and ORDER BY key verification
# ============================================================================
log "Phase 6: Table engine and ORDER BY key verification"

if [ "${PHASE3_STATUS}" = "PASS" ]; then
  ENGINE_RESULT=$(ch_query "
    SELECT engine, sorting_key
    FROM system.tables
    WHERE database='analytics_db' AND table='device_metrics'
  " 2>/dev/null)

  ENGINE_NAME=$(echo "${ENGINE_RESULT}" | awk '{print $1}' 2>/dev/null || echo "")
  SORTING_KEY=$(echo "${ENGINE_RESULT}" | awk '{print $2}' 2>/dev/null || echo "")

  ENGINE_OK=false
  KEY_OK=false

  if echo "${ENGINE_NAME}" | grep -qi "MergeTree"; then
    ENGINE_OK=true
  fi
  if echo "${SORTING_KEY}" | grep -qi "device_type.*processed_timestamp"; then
    KEY_OK=true
  fi

  if [ "${ENGINE_OK}" = true ] && [ "${KEY_OK}" = true ]; then
    PHASE6_STATUS="PASS"
    PHASE6_DETAIL="Engine=MergeTree ORDER BY (device_type, processed_timestamp)"
    log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
  elif [ "${ENGINE_OK}" = true ]; then
    PHASE6_STATUS="WARN"
    PHASE6_DETAIL="Engine=MergeTree OK but sorting_key='${SORTING_KEY}' differs from expected"
    log "Phase 6: ${PHASE6_DETAIL}"
  else
    PHASE6_STATUS="FAIL"
    PHASE6_DETAIL="Engine='${ENGINE_NAME}' is not MergeTree"
    OVERALL_FAILED=1
  fi
else
  PHASE6_STATUS="SKIP"
  PHASE6_DETAIL="ClickHouse not reachable -- skipping"
fi

# ============================================================================
# Phase 7: INSERT/SELECT round-trip test
# ============================================================================
log "Phase 7: INSERT/SELECT round-trip test"

if [ "${PHASE3_STATUS}" = "PASS" ] && [ "${PHASE5_STATUS}" != "FAIL" ]; then
  TEST_EVENT_ID="verify-$(date +%s)"
  TEST_DEVICE_TYPE="verify-device"
  TEST_METRIC_VALUE=42.5
  TEST_TS="2026-01-01 00:00:00"

  # Insert test row
  INSERT_RESULT=$(ch_query "
    INSERT INTO analytics_db.device_metrics (event_id, device_type, metric_value, processed_timestamp)
    VALUES ('${TEST_EVENT_ID}', '${TEST_DEVICE_TYPE}', ${TEST_METRIC_VALUE}, '${TEST_TS}')
  " 2>&1)

  INSERT_EXIT=$?

  if [ ${INSERT_EXIT} -eq 0 ] || [ -z "${INSERT_RESULT}" ]; then
    # SELECT it back
    SELECT_RESULT=$(ch_query "
      SELECT event_id, device_type, metric_value, processed_timestamp
      FROM analytics_db.device_metrics
      WHERE event_id='${TEST_EVENT_ID}'
    " 2>&1)

    if echo "${SELECT_RESULT}" | grep -q "${TEST_EVENT_ID}"; then
      PHASE7_STATUS="PASS"
      PHASE7_DETAIL="INSERT/SELECT round-trip verified (event_id=${TEST_EVENT_ID})"
      log "Phase 7: ${PHASE7_DETAIL} -- PASSED"

      # Clean up test data
      ch_query "ALTER TABLE analytics_db.device_metrics DELETE WHERE event_id='${TEST_EVENT_ID}'" \
        > /dev/null 2>&1 || true
    else
      PHASE7_STATUS="WARN"
      PHASE7_DETAIL="INSERT succeeded but SELECT returned: $(echo "${SELECT_RESULT}" | tr '\n' ' ' | head -c 80)"
      log "Phase 7: ${PHASE7_DETAIL}"
    fi
  else
    PHASE7_STATUS="WARN"
    PHASE7_DETAIL="INSERT failed: $(echo "${INSERT_RESULT}" | tr '\n' ' ' | head -c 80)"
    log "Phase 7: ${PHASE7_DETAIL}"
  fi
elif [ "${PHASE3_STATUS}" != "PASS" ]; then
  PHASE7_STATUS="SKIP"
  PHASE7_DETAIL="ClickHouse not reachable -- skipping round-trip test"
else
  PHASE7_STATUS="SKIP"
  PHASE7_DETAIL="Table not found -- skipping round-trip test"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== ClickHouse Health Verification Summary ==="
printf "%-12s %-12s %-60s\n" "PHASE"          "STATUS" "DETAIL"
printf "%-12s %-12s %-60s\n" "-----"          "------" "------"
printf "%-12s %-12s %-60s\n" "1-Pod-Health"   "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-12s %-12s %-60s\n" "2-PVC-Binding"  "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-12s %-12s %-60s\n" "3-Connectivity" "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-12s %-12s %-60s\n" "4-Database"     "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-12s %-12s %-60s\n" "5-Schema"       "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-12s %-12s %-60s\n" "6-Engine+Key"   "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
printf "%-12s %-12s %-60s\n" "7-RoundTrip"    "${PHASE7_STATUS}" "${PHASE7_DETAIL}"
echo "================================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "================================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-clickhouse: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-clickhouse: ALL CHECKS PASSED"
exit 0

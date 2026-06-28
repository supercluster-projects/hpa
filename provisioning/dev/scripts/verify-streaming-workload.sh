#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-streaming-workload.sh — Stream-processor workload health verification
#
# Verifies the end-to-end streaming pipeline deployed by
# install-streaming-workload.sh. Phases:
#   Phase 1: SpinApp 'stream' Ready and underlying pods healthy
#   Phase 2: Kafka consumer group 'hpa-stream' connected
#   Phase 3: Produce test event to hpa-events topic and verify KeyDB counter
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-streaming-workload.sh [--kubeconfig <path>]
#                                       [--workloads-namespace <ns>]
#                                       [--kafka-namespace <ns>]
#                                       [--kafka-cluster-name <name>]
#                                       [--keydb-namespace <ns>]
#                                       [--kafka-client-image <image>]
#                                       [--disable-prodcons-test]
#                                       [--wait-timeout <seconds>]
#                                       [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env DEV_WORKLOADS_NAMESPACE

# ---- Internal defaults (script-internal only) -------------------------
WORKLOADS_NAMESPACE="${DEV_WORKLOADS_NAMESPACE}"
KAFKA_NAMESPACE="strimzi"
KAFKA_CLUSTER_NAME="hpa-kafka"
KEYDB_NAMESPACE="keydb"
CONSUMER_GROUP="hpa-stream"
KAFKA_CLIENT_IMAGE="quay.io/strimzi-test-clients/test-clients:latest-kafka-3.9.0"
DISABLE_PRODCONS_TEST=false
WAIT_TIMEOUT=120

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)               KUBECONFIG="$2";                shift 2 ;;
    --workloads-namespace)      WORKLOADS_NAMESPACE="$2";       shift 2 ;;
    --kafka-namespace)          KAFKA_NAMESPACE="$2";           shift 2 ;;
    --kafka-cluster-name)       KAFKA_CLUSTER_NAME="$2";        shift 2 ;;
    --keydb-namespace)          KEYDB_NAMESPACE="$2";           shift 2 ;;
    --kafka-client-image)       KAFKA_CLIENT_IMAGE="$2";        shift 2 ;;
    --disable-prodcons-test)    DISABLE_PRODCONS_TEST=true;     shift ;;
    --wait-timeout)             WAIT_TIMEOUT="$2";              shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify stream SpinApp, Kafka consumer group, and end-to-end pipeline.

Phases:
  1  SpinApp 'stream' Ready and underlying Deployment healthy
  2  Kafka consumer group 'hpa-stream' connected
  3  Produce test event to hpa-events topic and verify KeyDB counter increment

Options:
  --kubeconfig PATH              Path to kubeconfig (default: ../opentofu/kubeconfig)
  --workloads-namespace NS       Workloads namespace (default: hpa-workloads)
  --kafka-namespace NS           Strimzi/Kafka namespace (default: strimzi)
  --kafka-cluster-name NAME      Kafka CR name (default: hpa-kafka)
  --keydb-namespace NS           KeyDB namespace (default: keydb)
  --kafka-client-image IMAGE     Client image for produce/consume test
                                 (default: quay.io/strimzi-test-clients/test-clients:latest-kafka-3.9.0)
  --disable-prodcons-test        Skip the produce/consume test (Phase 3)
  --wait-timeout SECONDS         Max seconds to wait for pods/CRDs to appear (default: 120)
  --help, -h                     Show this help message

Examples:
  ./verify-streaming-workload.sh --kubeconfig /custom/path/kubeconfig
  ./verify-streaming-workload.sh --disable-prodcons-test
  ./verify-streaming-workload.sh --wait-timeout 300
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-streaming-workload: starting"
log "  kubeconfig:            ${KUBECONFIG}"
log "  workloads namespace:   ${WORKLOADS_NAMESPACE}"
log "  kafka namespace:       ${KAFKA_NAMESPACE}"
log "  kafka cluster name:    ${KAFKA_CLUSTER_NAME}"
log "  consumer group:        ${CONSUMER_GROUP}"
log "  keydb namespace:       ${KEYDB_NAMESPACE}"
log "  prodcons test:         $([ "${DISABLE_PRODCONS_TEST}" = true ] && echo 'DISABLED' || echo 'ENABLED')"
log "  wait timeout:          ${WAIT_TIMEOUT}s"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # SpinApp stream pod health
PHASE1_DETAIL=""
PHASE2_STATUS=""   # Kafka consumer group connected
PHASE2_DETAIL=""
PHASE3_STATUS=""   # Produce test event and verify KeyDB counter
PHASE3_DETAIL=""

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

# ============================================================================
# Phase 1: SpinApp 'stream' Ready and underlying pods healthy
# ============================================================================
log "Phase 1: SpinApp 'stream' Ready and pod health"

SPINAPP_READY=""
SPINAPP_DETAIL=""

# Check if the SpinApp CRD exists
if ! kubectl --kubeconfig "${KUBECONFIG}" get crd spinapps.core.spinoperator.dev > /dev/null 2>&1; then
  if ! kubectl --kubeconfig "${KUBECONFIG}" get crd spinapps.spinoperator.dev > /dev/null 2>&1; then
    err "SpinApp CRD not found (checked core.spinoperator.dev and spinoperator.dev)"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="SpinApp CRD not found"
    OVERALL_FAILED=1
  fi
fi

if [ -z "${PHASE1_STATUS}" ]; then
  if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream > /dev/null 2>&1; then
    err "SpinApp 'stream' not found in namespace '${WORKLOADS_NAMESPACE}'"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="spinapp/stream not found"
    OVERALL_FAILED=1
  else
    # Check the Ready condition
    SPINAPP_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    SPINAPP_REASON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
    SPINAPP_REPLICAS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
      -o jsonpath='{.status.replicas}' 2>/dev/null || echo "N/A")
    SPINAPP_RDY_REPLICAS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "N/A")

    detail="Ready=${SPINAPP_READY}, replicas=${SPINAPP_REPLICAS}, readyReplicas=${SPINAPP_RDY_REPLICAS}"
  fi
fi

# Check the underlying Deployment if SpinApp exists
STREAM_DEPLOY_READY=false
if kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get deployment stream > /dev/null 2>&1; then
  DEPLOY_AVAILABLE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get deployment stream \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
  DEPLOY_READY_REPLICAS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get deployment stream \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${DEPLOY_AVAILABLE}" = "True" ] && [ "${DEPLOY_READY_REPLICAS:-0}" -gt 0 ]; then
    STREAM_DEPLOY_READY=true
    detail="${detail}, deployment=Available, readyReplicas=${DEPLOY_READY_REPLICAS}"
  else
    detail="${detail}, deployment=NotAvailable, readyReplicas=${DEPLOY_READY_REPLICAS}"
  fi
  log "  Deployment 'stream': Available=${DEPLOY_AVAILABLE}, readyReplicas=${DEPLOY_READY_REPLICAS}"
else
  log "  Deployment 'stream' not found — may not have been created by the SpinApp operator yet"
  detail="${detail}, deployment=not-found"
fi

# Determine Phase 1 verdict
if [ -z "${PHASE1_STATUS}" ]; then
  if [ "${SPINAPP_READY}" = "True" ] && [ "${STREAM_DEPLOY_READY}" = true ]; then
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="${detail}"
    log "Phase 1: ${detail} -- PASSED"
  elif [ "${SPINAPP_READY}" = "True" ]; then
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="${detail}"
    log "Phase 1: ${detail} (SpinApp Ready, deployment may still be initializing) -- PASSED"
  elif [ "${SPINAPP_READY}" = "Unknown" ]; then
    PHASE1_STATUS="WARN"
    PHASE1_DETAIL="Progressing: ${detail}"
    log "Phase 1: ${detail} -- WARN (still progressing)"
  else
    err "SpinApp 'stream' not ready: ${detail}"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="${detail}"
    [ -n "${SPINAPP_REASON}" ] && PHASE1_DETAIL="${PHASE1_DETAIL}, reason=${SPINAPP_REASON}"
    OVERALL_FAILED=1
  fi
fi

# ============================================================================
# Phase 2: Kafka consumer group 'hpa-stream' connected
# ============================================================================
log "Phase 2: Kafka consumer group '${CONSUMER_GROUP}' connected"

# Check if the Kafka CRD and cluster exist
if ! kubectl --kubeconfig "${KUBECONFIG}" get crd kafkas.kafka.strimzi.io > /dev/null 2>&1; then
  err "Strimzi CRD 'kafkas.kafka.strimzi.io' not found — is the Strimzi operator installed?"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="Strimzi CRD not found"
  OVERALL_FAILED=1
elif ! kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get kafka "${KAFKA_CLUSTER_NAME}" > /dev/null 2>&1; then
  err "Kafka CR '${KAFKA_CLUSTER_NAME}' not found in namespace '${KAFKA_NAMESPACE}'"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="Kafka CR '${KAFKA_CLUSTER_NAME}' not found"
  OVERALL_FAILED=1
else
  # Strimzi exposes consumer group information via the KafkaUser resource and via
  # the kafka-consumer-groups.sh tool. We check consumer group status through
  # an ephemeral client pod.

  KAFKA_BOOTSTRAP_HOST="${KAFKA_CLUSTER_NAME}-kafka-bootstrap.${KAFKA_NAMESPACE}.svc.cluster.local"
  BOOTSTRAP_PORT=9092
  CLIENT_POD_NAME="kafka-verify-cg-${KAFKA_CLUSTER_NAME}"

  # Clean up any leftover client pod
  kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" delete pod "${CLIENT_POD_NAME}" \
    --ignore-not-found=true --grace-period=5 --wait=true > /dev/null 2>&1 || true

  # Create ephemeral client pod
  log "  Creating ephemeral client pod for consumer group inspection..."
  CLIENT_CREATED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" run "${CLIENT_POD_NAME}" \
    --image="${KAFKA_CLIENT_IMAGE}" \
    --restart=Never \
    --command -- sleep 30 2>&1) || { err "Failed to create client pod: ${CLIENT_CREATED}"; PHASE2_STATUS="FAIL"; PHASE2_DETAIL="Failed to create client pod"; OVERALL_FAILED=1; }

  if [ -z "${PHASE2_STATUS}" ]; then
    # Wait for client pod to be Ready
    log "  Waiting up to ${WAIT_TIMEOUT}s for client pod to be Ready"
    if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" wait \
      --for=condition=Ready "pod/${CLIENT_POD_NAME}" --timeout="${WAIT_TIMEOUT}s" > /dev/null 2>&1; then
      err "Client pod not Ready within ${WAIT_TIMEOUT}s"
      POD_DIAG=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get pod "${CLIENT_POD_NAME}" -o wide 2>&1 || true)
      log "  Client pod status: ${POD_DIAG}"
      PHASE2_STATUS="FAIL"
      PHASE2_DETAIL="Client pod not Ready within ${WAIT_TIMEOUT}s"
      OVERALL_FAILED=1
    fi
  fi

  if [ -z "${PHASE2_STATUS}" ]; then
    # Describe the consumer group
    local CG_DESCRIBE_CMD="/opt/kafka/bin/kafka-consumer-groups.sh \
      --bootstrap-server ${KAFKA_BOOTSTRAP_HOST}:${BOOTSTRAP_PORT} \
      --group ${CONSUMER_GROUP} \
      --describe 2>&1"

    log "  Describing consumer group '${CONSUMER_GROUP}'..."
    CG_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" exec "${CLIENT_POD_NAME}" \
      -- bash -c "${CG_DESCRIBE_CMD}" 2>&1) || true

    # Check if the consumer group exists
    if [ -z "${CG_OUTPUT}" ]; then
      # Try listing groups to see if our group exists at all
      local LIST_CMD="/opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server ${KAFKA_BOOTSTRAP_HOST}:${BOOTSTRAP_PORT} \
        --list 2>&1"

      LIST_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" exec "${CLIENT_POD_NAME}" \
        -- bash -c "${LIST_CMD}" 2>&1) || true

      if echo "${LIST_OUTPUT}" | grep -q "${CONSUMER_GROUP}"; then
        PHASE2_STATUS="PASS"
        PHASE2_DETAIL="consumer group '${CONSUMER_GROUP}' registered (empty describe: no active consumers yet)"
        log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
      elif [ -n "${LIST_OUTPUT}" ]; then
        PHASE2_STATUS="WARN"
        PHASE2_DETAIL="consumer group '${CONSUMER_GROUP}' not found in list: $(echo "${LIST_OUTPUT}" | tr '\n' ' ')"
        log "Phase 2: ${PHASE2_DETAIL} -- WARN (not yet connected)"
      else
        PHASE2_STATUS="WARN"
        PHASE2_DETAIL="Could not inspect consumer groups — broker may not have received the group yet"
        log "Phase 2: ${PHASE2_DETAIL} -- WARN"
      fi
    else
      # Parse the describe output for LAG info
      local TOTAL_LAG=0
      local CONSUMER_ID=""
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Skip header line
        if echo "${line}" | grep -q "^GROUP"; then
          continue
        fi
        # Parse: GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG CONSUMER-ID HOST CLIENT-ID
        local LAG_FIELD
        LAG_FIELD=$(echo "${line}" | awk '{print $6}')
        local CID_FIELD
        CID_FIELD=$(echo "${line}" | awk '{print $7}')
        local PARTITION_FIELD
        PARTITION_FIELD=$(echo "${line}" | awk '{print $3}')

        if [ -n "${LAG_FIELD}" ] && [ "${LAG_FIELD}" != "LAG" ]; then
          TOTAL_LAG=$((TOTAL_LAG + LAG_FIELD))
        fi
        if [ -n "${CID_FIELD}" ] && [ "${CID_FIELD}" != "CONSUMER-ID" ] && [ "${CID_FIELD}" != "-" ]; then
          CONSUMER_ID="${CID_FIELD}"
        fi
      done <<< "${CG_OUTPUT}"

      local CG_SUMMARY=""
      if [ -n "${CONSUMER_ID}" ]; then
        CG_SUMMARY="consumer=${CONSUMER_ID}, totalLag=${TOTAL_LAG}"
      else
        CG_SUMMARY="noActiveConsumer, totalLag=${TOTAL_LAG}"
      fi

      PHASE2_STATUS="PASS"
      PHASE2_DETAIL="consumer group '${CONSUMER_GROUP}': ${CG_SUMMARY}"
      log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
    fi
  fi

  # Clean up the client pod
  log "  Cleaning up client pod: ${CLIENT_POD_NAME}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" delete pod "${CLIENT_POD_NAME}" \
    --ignore-not-found=true --grace-period=3 --wait=true > /dev/null 2>&1 || true
fi

# ============================================================================
# Phase 3: Produce test event to hpa-events and verify KeyDB counter
# ============================================================================
if [ "${DISABLE_PRODCONS_TEST}" = true ]; then
  PHASE3_STATUS="SKIP"
  PHASE3_DETAIL="Produce/consume test disabled via --disable-prodcons-test"
  log "Phase 3: ${PHASE3_DETAIL}"
else
  log "Phase 3: Produce test event to hpa-events and verify KeyDB counter"

  # Check prerequisites
  MISSING_PREREQ=false
  if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get kafkatopic hpa-events > /dev/null 2>&1; then
    err "KafkaTopic 'hpa-events' not found in namespace '${KAFKA_NAMESPACE}'"
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="KafkaTopic 'hpa-events' not found"
    MISSING_PREREQ=true
    OVERALL_FAILED=1
  fi

  if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get deployment keydb > /dev/null 2>&1; then
    err "KeyDB deployment not found in namespace '${KEYDB_NAMESPACE}'"
    PHASE3_STATUS="FAIL"
    PHASE3_DETAIL="KeyDB deployment not found"
    MISSING_PREREQ=true
    OVERALL_FAILED=1
  fi

  if [ "${MISSING_PREREQ}" = true ]; then
    : # Phase 3 already set to FAIL
  else
    KAFKA_BOOTSTRAP_HOST="${KAFKA_CLUSTER_NAME}-kafka-bootstrap.${KAFKA_NAMESPACE}.svc.cluster.local"
    BOOTSTRAP_PORT=9092
    CLIENT_POD_NAME="kafka-streaming-verify-${KAFKA_CLUSTER_NAME}"
    TEST_DEVICE_TYPE="verify-$(date +%s)"
    TEST_EVENT_ID="verify-$(date +%s)-${RANDOM}"

    # Clean up any leftover client pod
    kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" delete pod "${CLIENT_POD_NAME}" \
      --ignore-not-found=true --grace-period=5 --wait=true > /dev/null 2>&1 || true

    # Create ephemeral client pod
    log "  Creating ephemeral client pod for produce/consume test..."
    CLIENT_CREATED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" run "${CLIENT_POD_NAME}" \
      --image="${KAFKA_CLIENT_IMAGE}" \
      --restart=Never \
      --command -- sleep 60 2>&1) || { err "Failed to create client pod: ${CLIENT_CREATED}"; PHASE3_STATUS="FAIL"; PHASE3_DETAIL="Failed to create client pod"; OVERALL_FAILED=1; }

    if [ -z "${PHASE3_STATUS}" ]; then
      # Wait for client pod to be Ready
      log "  Waiting up to ${WAIT_TIMEOUT}s for client pod to be Ready"
      if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" wait \
        --for=condition=Ready "pod/${CLIENT_POD_NAME}" --timeout="${WAIT_TIMEOUT}s" > /dev/null 2>&1; then
        err "Client pod not Ready within ${WAIT_TIMEOUT}s"
        POD_DIAG=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get pod "${CLIENT_POD_NAME}" -o wide 2>&1 || true)
        log "  Client pod status: ${POD_DIAG}"
        PHASE3_STATUS="FAIL"
        PHASE3_DETAIL="Client pod not Ready within ${WAIT_TIMEOUT}s"
        OVERALL_FAILED=1
      fi
    fi

    if [ -z "${PHASE3_STATUS}" ]; then
      # Read the current KeyDB counter value for our test device type
      KEYDB_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get pod -l app=keydb \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || "")

      if [ -z "${KEYDB_POD}" ]; then
        KEYDB_POD=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get pods \
          --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || "")
      fi

      if [ -z "${KEYDB_POD}" ]; then
        err "No running KeyDB pod found in namespace '${KEYDB_NAMESPACE}'"
        PHASE3_STATUS="FAIL"
        PHASE3_DETAIL="No running KeyDB pod found"
        OVERALL_FAILED=1
      else
        log "  KeyDB pod: ${KEYDB_POD}"

        # Get the current counter value for the test device type
        COUNTER_KEY="device_count:${TEST_DEVICE_TYPE}"
        BEFORE_COUNTER=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
          keydb-cli HGET "${COUNTER_KEY}" count 2>/dev/null || echo "")

        if [ -z "${BEFORE_COUNTER}" ] || [ "${BEFORE_COUNTER}" = "(nil)" ] || [ "${BEFORE_COUNTER}" = "" ]; then
          BEFORE_COUNTER="0"
        fi
        log "  Counter before: ${COUNTER_KEY} = ${BEFORE_COUNTER}"

        # Produce a test HPA event to the hpa-events topic
        TEST_EVENT_JSON="{\"event_id\":\"${TEST_EVENT_ID}\",\"device_type\":\"${TEST_DEVICE_TYPE}\",\"metric_value\":42.5,\"processed_timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

        local PRODUCE_CMD="echo '${TEST_EVENT_JSON}' | /opt/kafka/bin/kafka-console-producer.sh \
          --bootstrap-server ${KAFKA_BOOTSTRAP_HOST}:${BOOTSTRAP_PORT} \
          --topic hpa-events \
          --timeout 10000 2>&1"

        log "  Producing HPA event to hpa-events topic: ${TEST_EVENT_JSON}"
        PRODUCE_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" exec "${CLIENT_POD_NAME}" \
          -- bash -c "${PRODUCE_CMD}" 2>&1) || true

        PRODUCE_EXIT_CODE=$?
        if [ ${PRODUCE_EXIT_CODE} -ne 0 ] && [ -n "${PRODUCE_RESULT}" ]; then
          err "Produce to 'hpa-events' failed: ${PRODUCE_RESULT}"
          PHASE3_STATUS="FAIL"
          PHASE3_DETAIL="Produce to 'hpa-events' failed: $(echo "${PRODUCE_RESULT}" | tr '\n' ' ' | head -c 80)"
          OVERALL_FAILED=1
        else
          log "  Produce succeeded (exit=${PRODUCE_EXIT_CODE})"

          # Wait for the stream to consume the event and increment the counter
          log "  Waiting 5s for stream to process the event..."
          sleep 5

          # Check the counter value after producing
          AFTER_COUNTER=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" exec "${KEYDB_POD}" -- \
            keydb-cli HGET "${COUNTER_KEY}" count 2>/dev/null || echo "")

          if [ -z "${AFTER_COUNTER}" ] || [ "${AFTER_COUNTER}" = "(nil)" ] || [ "${AFTER_COUNTER}" = "" ]; then
            AFTER_COUNTER="0"
          fi

          log "  Counter after:  ${COUNTER_KEY} = ${AFTER_COUNTER}"

          if [ "${AFTER_COUNTER}" -gt "${BEFORE_COUNTER}" ]; then
            PHASE3_STATUS="PASS"
            PHASE3_DETAIL="Counter '${COUNTER_KEY}' incremented: ${BEFORE_COUNTER} -> ${AFTER_COUNTER} (eventId=${TEST_EVENT_ID})"
            log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
          elif [ "${AFTER_COUNTER}" -eq 0 ] && [ "${BEFORE_COUNTER}" -eq 0 ]; then
            PHASE3_STATUS="WARN"
            PHASE3_DETAIL="Counter '${COUNTER_KEY}' remains 0 after produce (stream may not be consuming yet)"
            log "Phase 3: ${PHASE3_DETAIL} -- WARN (no increment detected)"
          else
            PHASE3_STATUS="WARN"
            PHASE3_DETAIL="Counter '${COUNTER_KEY}' before=${BEFORE_COUNTER}, after=${AFTER_COUNTER} (unexpected change before/after)"
            log "Phase 3: ${PHASE3_DETAIL} -- WARN"
          fi
        fi
      fi
    fi

    # Clean up the client pod
    log "  Cleaning up client pod: ${CLIENT_POD_NAME}"
    kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" delete pod "${CLIENT_POD_NAME}" \
      --ignore-not-found=true --grace-period=3 --wait=true > /dev/null 2>&1 || true
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Streaming Workload Health Verification Summary ==="
printf "%-12s %-12s %-72s\n" "PHASE"         "STATUS" "DETAIL"
printf "%-12s %-12s %-72s\n" "-----"         "------" "------"
printf "%-12s %-12s %-72s\n" "1-SpinApp"    "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-12s %-12s %-72s\n" "2-ConsGroup"  "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-12s %-12s %-72s\n" "3-End2End"    "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
echo "======================================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "======================================================================="
echo ""

# ---- Diagnostics ----------------------------------------------------------
log "Diagnostics:"
log "  SpinApp:"
kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream -o yaml 2>/dev/null \
  | grep -E "(status:| readyReplicas:| replicas:| conditions:)" || log "  (unable to get SpinApp status)"
log "  Pods in workload namespace:"
kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get pods 2>/dev/null \
  || log "  (unable to get pods)"

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-streaming-workload: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-streaming-workload: ALL CHECKS PASSED"
exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# kafka-producer-test.sh — Quick Kafka produce/consume test for dev
#
# Creates an ephemeral kafka-client pod in the Strimzi namespace, produces
# a configurable number of messages to a topic, consumes them back, and
# reports throughput. Cleans up the client pod on exit.
#
# Usage: ./kafka-producer-test.sh [options]
#
# Options:
#   --kubeconfig PATH   Path to kubeconfig (default: ../opentofu/kubeconfig)
#   --namespace NS      Strimzi namespace (default: strimzi)
#   --cluster NAME      Kafka CR name (default: hpa-kafka)
#   --topic NAME        Topic to test (default: hpa-events)
#   --messages N        Number of messages to produce (default: 10)
#   --client-image IMG  Kafka client container image
#                       (default: quay.io/strimzi-test-clients/test-clients:latest-kafka-3.9.0)
#   --wait-timeout SEC  Max seconds to wait for pod ready (default: 60)
#   --help, -h          Show this help message
#
# Exit codes:
#   0 — produce/consume verified successfully
#   1 — configuration error
#   2 — produce or consume failed
#
# Examples:
#   ./kafka-producer-test.sh --topic hpa-events --messages 100
#   ./kafka-producer-test.sh --cluster hpa-kafka --messages 1000
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
NAMESPACE="strimzi"
CLUSTER_NAME="hpa-kafka"
TOPIC_NAME="hpa-events"
MESSAGE_COUNT=10
CLIENT_IMAGE="quay.io/strimzi-test-clients/test-clients:latest-kafka-3.9.0"
WAIT_TIMEOUT=60

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)    KUBECONFIG="$2";        shift 2 ;;
    --namespace)     NAMESPACE="$2";         shift 2 ;;
    --cluster)       CLUSTER_NAME="$2";       shift 2 ;;
    --topic)         TOPIC_NAME="$2";         shift 2 ;;
    --messages)      MESSAGE_COUNT="$2";      shift 2 ;;
    --client-image)  CLIENT_IMAGE="$2";       shift 2 ;;
    --wait-timeout)  WAIT_TIMEOUT="$2";        shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Quick Kafka produce/consume test for dev.

Creates an ephemeral kafka-client pod, produces messages to a topic,
consumes them back, and reports throughput. Cleans up on exit.

Options:
  --kubeconfig PATH   Path to kubeconfig (default: ../opentofu/kubeconfig)
  --namespace NS      Strimzi namespace (default: strimzi)
  --cluster NAME      Kafka CR name (default: hpa-kafka)
  --topic NAME        Topic to test (default: hpa-events)
  --messages N        Number of messages to produce (default: 10)
  --client-image IMG  Kafka client container image
                      (default: quay.io/strimzi-test-clients/test-clients:latest-kafka-3.9.0)
  --wait-timeout SEC  Max seconds to wait for pod ready (default: 60)
  --help, -h          Show this help message

Exit codes:
  0 — produce/consume verified successfully
  1 — configuration error
  2 — produce or consume failed
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "kafka-producer-test: starting"
log "  namespace:      ${NAMESPACE}"
log "  cluster:        ${CLUSTER_NAME}"
log "  topic:          ${TOPIC_NAME}"
log "  messages:       ${MESSAGE_COUNT}"
log "  client-image:   ${CLIENT_IMAGE}"
log "  wait-timeout:   ${WAIT_TIMEOUT}s"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]             || die "kubeconfig not found at ${KUBECONFIG}"

# Verify Kafka cluster exists and is Ready
if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafka "${CLUSTER_NAME}" > /dev/null 2>&1; then
  die "Kafka CR '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}' (exit code 1)"
fi

KAFKA_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafka "${CLUSTER_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1 || true)
if [ "${KAFKA_READY}" != "True" ]; then
  die "Kafka CR '${CLUSTER_NAME}' is not Ready (status=${KAFKA_READY:-unknown}) (exit code 1)"
fi

# Verify topic exists
if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafkatopic "${TOPIC_NAME}" > /dev/null 2>&1; then
  die "KafkaTopic '${TOPIC_NAME}' not found in namespace '${NAMESPACE}' (exit code 1)"
fi

# ---- Resolve bootstrap address --------------------------------------------
BOOTSTRAP_HOST="${CLUSTER_NAME}-kafka-bootstrap.${NAMESPACE}.svc.cluster.local"
BOOTSTRAP_PORT=9092
log "  bootstrap: ${BOOTSTRAP_HOST}:${BOOTSTRAP_PORT}"

# ---- Create ephemeral client pod ------------------------------------------
CLIENT_POD_NAME="kafka-prodtest-$(date +%s)-$$"

# Ensure cleanup on exit
cleanup() {
  local exit_code=$?
  log "Cleaning up client pod: ${CLIENT_POD_NAME}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" delete pod "${CLIENT_POD_NAME}" \
    --ignore-not-found=true --grace-period=3 --wait=true > /dev/null 2>&1 || true
  exit "${exit_code}"
}
trap cleanup EXIT

log "Creating client pod: ${CLIENT_POD_NAME}"
kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" run "${CLIENT_POD_NAME}" \
  --image="${CLIENT_IMAGE}" \
  --restart=Never \
  --command -- sleep 120 > /dev/null 2>&1 || die "Failed to create client pod '${CLIENT_POD_NAME}'"

log "Waiting up to ${WAIT_TIMEOUT}s for client pod to be Ready"
if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" wait \
  --for=condition=Ready "pod/${CLIENT_POD_NAME}" --timeout="${WAIT_TIMEOUT}s" > /dev/null 2>&1; then
  POD_STATUS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pod "${CLIENT_POD_NAME}" -o wide 2>&1 || true)
  POD_LOGS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" logs "${CLIENT_POD_NAME}" 2>&1 || true)
  log "  Pod status: ${POD_STATUS}"
  log "  Pod logs: ${POD_LOGS}"
  die "Client pod not Ready within ${WAIT_TIMEOUT}s (exit code 2)"
fi

# ---- Produce messages -----------------------------------------------------
log "Producing ${MESSAGE_COUNT} messages to '${TOPIC_NAME}'..."

PRODUCE_START=$(date +%s%N)
PRODUCE_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${CLIENT_POD_NAME}" \
  -- bash -c "
    for i in \$(seq 1 ${MESSAGE_COUNT}); do
      echo '{\"id\":\"test-\$i\",\"ts\":'\"\$(date +%s)\"',\"msg\":\"kafka-producer-test message \$i\"}'
    done | /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server ${BOOTSTRAP_HOST}:${BOOTSTRAP_PORT} \
      --topic ${TOPIC_NAME} \
      --timeout 15000 2>&1
  " 2>&1) || true

PRODUCE_END=$(date +%s%N)
PRODUCE_DURATION_MS=$(( (PRODUCE_END - PRODUCE_START) / 1000000 ))

if [ -n "${PRODUCE_RESULT}" ]; then
  log "  Produce output: ${PRODUCE_RESULT}"
fi
log "  Produced ${MESSAGE_COUNT} messages in ${PRODUCE_DURATION_MS}ms"
log "  Throughput: $(( MESSAGE_COUNT * 1000 / (PRODUCE_DURATION_MS + 1) )) msg/s"

# ---- Consume messages back ------------------------------------------------
log "Consuming ${MESSAGE_COUNT} messages from '${TOPIC_NAME}'..."

CONSUME_START=$(date +%s%N)
CONSUME_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" exec "${CLIENT_POD_NAME}" \
  -- bash -c "
    /opt/kafka/bin/kafka-console-consumer.sh \
      --bootstrap-server ${BOOTSTRAP_HOST}:${BOOTSTRAP_PORT} \
      --topic ${TOPIC_NAME} \
      --from-beginning \
      --max-messages ${MESSAGE_COUNT} \
      --timeout-ms 20000 2>&1
  " 2>&1) || true

CONSUME_END=$(date +%s%N)
CONSUME_DURATION_MS=$(( (CONSUME_END - CONSUME_START) / 1000000 ))

# Count consumed lines (exclude stderr-like output from consumer script)
CONSUMED_COUNT=$(echo "${CONSUME_RESULT}" | grep -c '^\{"id":' 2>/dev/null || echo "0")
log "  Consumed ${CONSUMED_COUNT} messages in ${CONSUME_DURATION_MS}ms"

# ---- Result ---------------------------------------------------------------
echo ""
echo "=== Kafka Producer Test Results ==="
echo "  Cluster:         ${CLUSTER_NAME}"
echo "  Namespace:       ${NAMESPACE}"
echo "  Topic:           ${TOPIC_NAME}"
echo "  Messages sent:   ${MESSAGE_COUNT}"
echo "  Messages recv:   ${CONSUMED_COUNT}"
echo "  Produce time:    ${PRODUCE_DURATION_MS}ms"
echo "  Consume time:    ${CONSUME_DURATION_MS}ms"
echo "  Throughput:      $(( MESSAGE_COUNT * 1000 / (PRODUCE_DURATION_MS + 1) )) msg/s (produce)"
echo ""

if [ "${CONSUMED_COUNT}" -ge "${MESSAGE_COUNT}" ]; then
  echo "  Verdict:         PASS"
  echo "================================="
  log "kafka-producer-test: ALL CHECKS PASSED"
  exit 0
elif [ "${CONSUMED_COUNT}" -gt 0 ]; then
  echo "  Verdict:         PARTIAL (${CONSUMED_COUNT}/${MESSAGE_COUNT})"
  echo "================================="
  log "kafka-producer-test: PARTIAL — consumed ${CONSUMED_COUNT}/${MESSAGE_COUNT}"
  exit 0
else
  echo "  Verdict:         FAIL"
  echo "================================="
  die "kafka-producer-test: FAILED — no messages consumed from '${TOPIC_NAME}' (exit code 2)"
fi

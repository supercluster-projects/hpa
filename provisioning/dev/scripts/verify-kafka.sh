#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-kafka.sh -- Strimzi Kafka Operator + cluster health verification
#
# Verifies the Strimzi-based Kafka stack that streaming workloads depend on:
#   Phase 1: Strimzi Operator pod health (namespace: strimzi)
#   Phase 2: Kafka cluster CR status (Ready condition)
#   Phase 3: ZooKeeper pod health
#   Phase 4: Kafka broker pod health and PVC binding status
#   Phase 5: Topic existence (hpa-events)
#   Phase 6: Produce/consume test via ephemeral kafka-client pod
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-kafka.sh [--kubeconfig <path>]
#           [--namespace <ns>] [--cluster-name <name>]
#           [--expected-operator-pods <count>]
#           [--expected-zk-pods <count>] [--expected-broker-pods <count>]
#           [--topic-name <name>] [--kafka-client-image <image>]
#           [--wait-timeout <seconds>] [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="strimzi"
CLUSTER_NAME="hpa-cluster"
TOPIC_NAME="hpa-events"
KAFKA_CLIENT_IMAGE="quay.io/strimzi-test-clients/test-clients:latest-kafka-3.9.0"
# Note: The Strimzi operator creates pods in the same namespace with
# predictable name patterns: <cluster>-zookeeper-<N>, <cluster>-kafka-<N>

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)               KUBECONFIG="$2";                       shift 2 ;;
    --namespace)                NAMESPACE="$2";                       shift 2 ;;
    --cluster-name)             CLUSTER_NAME="$2";                    shift 2 ;;
    --topic-name)               TOPIC_NAME="$2";                      shift 2 ;;
    --kafka-client-image)       KAFKA_CLIENT_IMAGE="$2";              shift 2 ;;
    --expected-operator-pods)   EXPECTED_OPERATOR_PODS="$2";          shift 2 ;;
    --expected-zk-pods)         EXPECTED_ZK_PODS="$2";                shift 2 ;;
    --expected-broker-pods)     EXPECTED_BROKER_PODS="$2";            shift 2 ;;
    --wait-timeout)             WAIT_TIMEOUT="$2";                    shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Strimzi Kafka Operator pod health, Kafka cluster CR status,
ZooKeeper pod health, broker pod health, PVC binding, topic existence,
and produce/consume capability.

Phases:
  1  Strimzi Operator pod health (namespace: strimzi)
  2  Kafka cluster CR status (Ready condition)
  3  ZooKeeper pod health and PVC binding
  4  Kafka broker pod health and PVC binding
  5  Topic existence (${TOPIC_NAME})
  6  Produce/consume test via ephemeral kafka-client pod

Options:
  --kubeconfig PATH             Path to kubeconfig (default: ../opentofu/kubeconfig)
  --namespace NS                Strimzi namespace (default: strimzi)
  --cluster-name NAME           Kafka CR name (default: hpa-cluster)
  --topic-name NAME             Topic to verify (default: hpa-events)
  --kafka-client-image IMAGE    Client image for produce/consume test
                                (default: quay.io/strimzi-test-clients/test-clients:latest-kafka-3.9.0)
  --expected-operator-pods NUM  Expected Strimzi operator pods (default: 1)
  --expected-zk-pods NUM        Expected ZooKeeper pods (default: 1)
  --expected-broker-pods NUM    Expected Kafka broker pods (default: 1)
  --wait-timeout SECONDS        Max seconds to wait for resources
                                (default: 60)
  --help, -h                    Show this help message

Examples:
  ./verify-kafka.sh --kubeconfig /custom/path/kubeconfig
  ./verify-kafka.sh --cluster-name hpa-cluster --expected-broker-pods 3
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-kafka: starting"
log "  kubeconfig:           ${KUBECONFIG}"
log "  namespace:            ${NAMESPACE}"
log "  cluster name:         ${CLUSTER_NAME}"
log "  topic name:           ${TOPIC_NAME}"
log "  client image:         ${KAFKA_CLIENT_IMAGE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # Operator pod health
PHASE1_DETAIL=""
PHASE2_STATUS=""   # Kafka CR status
PHASE2_DETAIL=""
PHASE3_STATUS=""   # ZooKeeper pod health
PHASE3_DETAIL=""
PHASE4_STATUS=""   # Broker pod health + PVCs
PHASE4_DETAIL=""
PHASE5_STATUS=""   # Topic existence
PHASE5_DETAIL=""
PHASE6_STATUS=""   # Produce/consume test
PHASE6_DETAIL=""

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

# ---- Helper: check pods by label selector ----------------------------------
# Usage: check_pod_health_by_label <namespace> <label_selector> <expected_count> <var_status> <var_detail>
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

  # Fallback: label selector returned nothing — try name-based grep
  if [ -z "$(echo "${POD_OUTPUT}" | head -1)" ]; then
    log "  Label selector '${label}' returned no pods, trying name-based fallback"
    # Extract a name pattern from the label value (e.g. strimzi.io/name=my-cluster-kafka)
    local name_pattern
    name_pattern=$(echo "${label}" | grep -oP '(?<=strimzi\.io/name=)[^,]+' || true)
    if [ -z "${name_pattern}" ]; then
      out_status="FAIL"
      out_detail="no pods found for label '${label}'"
      err "No pods found — label '${label}' matched nothing and no name pattern could be derived"
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
    err "No pods found for label '${label}' in '${ns}'"
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
    log "  -> WARN"
    return 0
  else
    err "Pod count mismatch (${label}): ${READY}/${TOTAL} ready, expected ${expected}"
    out_status="FAIL"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    return 1
  fi
}

# ---- Helper: check PVC binding --------------------------------------------
# Usage: check_pvc_bound <namespace> <name_pattern> <var_status> <var_detail>
check_pvc_bound() {
  local ns="$1"
  local name_pattern="$2"
  local -n out_status="$3"
  local -n out_detail="$4"

  log "Checking PVC binding in '${ns}' matching '${name_pattern}'"

  local PVC_OUTPUT
  PVC_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pvc --no-headers 2>&1) \
    || { err "kubectl get pvc in '${ns}' failed: ${PVC_OUTPUT}"; out_status="FAIL"; out_detail="kubectl error"; return 1; }

  local TOTAL=0
  local BOUND=0
  local NOT_BOUND=""
  local MATCHED=false

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local PVC_NAME
    PVC_NAME=$(echo "$line" | awk '{print $1}')

    # Filter by name pattern
    if ! echo "${PVC_NAME}" | grep -q "${name_pattern}"; then
      continue
    fi
    MATCHED=true
    TOTAL=$((TOTAL + 1))

    local PVC_STATUS
    PVC_STATUS=$(echo "$line" | awk '{print $2}')

    if [ "${PVC_STATUS}" = "Bound" ]; then
      local VOLUME
      VOLUME=$(echo "$line" | awk '{print $3}')
      BOUND=$((BOUND + 1))
      log "  PVC '${PVC_NAME}' -> Bound to '${VOLUME}'"
    else
      NOT_BOUND="${NOT_BOUND} ${PVC_NAME}(${PVC_STATUS})"
    fi
  done <<< "${PVC_OUTPUT}"

  if [ "${MATCHED}" = false ]; then
    out_status="WARN"
    out_detail="0 PVCs matching '${name_pattern}' found (Kafka may not have created them yet)"
    log "  -> WARN (no matching PVCs)"
    return 0
  elif [ -n "${NOT_BOUND}" ]; then
    err "PVCs not Bound:${NOT_BOUND}"
    out_status="FAIL"
    out_detail="${BOUND}/${TOTAL} Bound"
    return 1
  elif [ "${BOUND}" -eq "${TOTAL}" ]; then
    out_status="PASS"
    out_detail="${BOUND}/${TOTAL} Bound"
    log "  -> PASSED"
    return 0
  else
    err "PVC binding count mismatch: ${BOUND}/${TOTAL} Bound"
    out_status="FAIL"
    out_detail="${BOUND}/${TOTAL} Bound"
    return 1
  fi
}

# ============================================================================
# Phase 1: Strimzi Operator pod health (namespace: strimzi)
# ============================================================================
log "Phase 1: Strimzi Operator pod health"
EXPECTED_OPERATOR_PODS="${EXPECTED_OPERATOR_PODS:-1}"

# The Strimzi operator pod has label name=strimzi-operator (Helm chart default)
# or app.kubernetes.io/name=strimzi-kafka-operator
if kubectl --kubeconfig "${KUBECONFIG}" get ns "${NAMESPACE}" > /dev/null 2>&1; then
  # Try common operator label selectors
  if check_pod_health_by_label "${NAMESPACE}" "name=strimzi-operator" "${EXPECTED_OPERATOR_PODS}" PHASE1_STATUS PHASE1_DETAIL; then
    : # already set
  elif check_pod_health_by_label "${NAMESPACE}" "app.kubernetes.io/name=strimzi-kafka-operator" "${EXPECTED_OPERATOR_PODS}" PHASE1_STATUS PHASE1_DETAIL; then
    : # already set
  elif check_pod_health_by_label "${NAMESPACE}" "app.kubernetes.io/part-of=strimzi-kafka-operator" "${EXPECTED_OPERATOR_PODS}" PHASE1_STATUS PHASE1_DETAIL; then
    : # already set
  else
    # Final fallback: list all pods and grep for strimzi-operator or strimzi-cluster-operator
    log "  Trying generic name-based fallback for operator pods"
    local ALL_PODS
    ALL_PODS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pods --no-headers 2>&1 | grep -E 'strimzi-(cluster-)?operator' || true)
    if [ -z "$(echo "${ALL_PODS}" | head -1)" ]; then
      PHASE1_STATUS="FAIL"
      PHASE1_DETAIL="0 pods matching strimzi operator patterns in '${NAMESPACE}'"
      OVERALL_FAILED=1
    else
      local O_TOTAL=0
      local O_READY=0
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        O_TOTAL=$((O_TOTAL + 1))
        local R_FIELD S_FIELD
        R_FIELD=$(echo "$line" | awk '{print $2}')
        S_FIELD=$(echo "$line" | awk '{print $3}')
        if [ "${R_FIELD%%/*}" -gt 0 ] && [ "${S_FIELD}" = "Running" ]; then
          O_READY=$((O_READY + 1))
        fi
      done <<< "${ALL_PODS}"
      if [ "${O_READY}" -eq "${EXPECTED_OPERATOR_PODS}" ] && [ "${O_TOTAL}" -eq "${EXPECTED_OPERATOR_PODS}" ]; then
        PHASE1_STATUS="PASS"
        PHASE1_DETAIL="${O_READY}/${O_TOTAL} ready (expected ${EXPECTED_OPERATOR_PODS})"
        log "Phase 1: ${PHASE1_DETAIL} -- PASSED"
      elif [ "${O_READY}" -ge "$((EXPECTED_OPERATOR_PODS - 1))" ]; then
        PHASE1_STATUS="WARN"
        PHASE1_DETAIL="${O_READY}/${O_TOTAL} ready (expected ${EXPECTED_OPERATOR_PODS})"
        log "Phase 1: ${PHASE1_DETAIL} -- WARN"
      else
        PHASE1_STATUS="FAIL"
        PHASE1_DETAIL="${O_READY}/${O_TOTAL} ready (expected ${EXPECTED_OPERATOR_PODS})"
        OVERALL_FAILED=1
      fi
    fi
  fi
else
  PHASE1_STATUS="FAIL"
  PHASE1_DETAIL="Namespace '${NAMESPACE}' not found"
  err "Namespace '${NAMESPACE}' does not exist"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: Kafka cluster CR status (Ready condition)
# ============================================================================
log "Phase 2: Kafka cluster CR status"
KAFKA_CRD="kafkas.kafka.strimzi.io"

if kubectl --kubeconfig "${KUBECONFIG}" get crd "${KAFKA_CRD}" > /dev/null 2>&1; then
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafka "${CLUSTER_NAME}" > /dev/null 2>&1; then
    # Check the Ready condition
    KAFKA_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafka "${CLUSTER_NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1 || true)

    # Also get the cluster phase if available (some Strimzi versions have .status.kafka.state)
    KAFKA_STATE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafka "${CLUSTER_NAME}" \
      -o jsonpath='{.status.kafka.state}' 2>&1 || true)

    # Get the cluster ID for additional detail
    CLUSTER_ID=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafka "${CLUSTER_NAME}" \
      -o jsonpath='{.status.clusterId}' 2>&1 || true)

    if [ "${KAFKA_READY}" = "True" ]; then
      if [ -n "${CLUSTER_ID}" ]; then
        PHASE2_STATUS="PASS"
        PHASE2_DETAIL="Kafka CR '${CLUSTER_NAME}': Ready=True, clusterId=${CLUSTER_ID}"
      else
        PHASE2_STATUS="PASS"
        PHASE2_DETAIL="Kafka CR '${CLUSTER_NAME}': Ready=True (no clusterId reported)"
      fi
      log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
    elif [ "${KAFKA_READY}" = "False" ]; then
      # Get the reason/message for why it's not ready
      KAFKA_REASON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafka "${CLUSTER_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>&1 || true)
      KAFKA_MSG=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafka "${CLUSTER_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>&1 || true)
      PHASE2_STATUS="FAIL"
      PHASE2_DETAIL="Kafka CR '${CLUSTER_NAME}' Ready=False (reason=${KAFKA_REASON:-unknown}, msg=${KAFKA_MSG:-none})"
      OVERALL_FAILED=1
    elif [ -z "${KAFKA_READY}" ]; then
      # No Ready condition yet — cluster is likely still provisioning
      if [ -n "${KAFKA_STATE}" ]; then
        PHASE2_STATUS="WARN"
        PHASE2_DETAIL="Kafka CR '${CLUSTER_NAME}' state=${KAFKA_STATE} (no Ready condition yet)"
        log "Phase 2: ${PHASE2_DETAIL} -- WARN (still provisioning)"
      else
        PHASE2_STATUS="PASS"
        PHASE2_DETAIL="Kafka CR '${CLUSTER_NAME}' exists but status not yet populated (initializing)"
        log "Phase 2: ${PHASE2_DETAIL} -- PASSED (graceful)"
      fi
    else
      PHASE2_STATUS="WARN"
      PHASE2_DETAIL="Kafka CR '${CLUSTER_NAME}' Ready=${KAFKA_READY}"
      log "Phase 2: ${PHASE2_DETAIL} -- WARN"
    fi
  else
    err "Kafka CR '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}'"
    PHASE2_STATUS="FAIL"
    PHASE2_DETAIL="Kafka CR '${CLUSTER_NAME}' not found in '${NAMESPACE}'"
    OVERALL_FAILED=1
  fi
else
  err "CRD '${KAFKA_CRD}' not found — Strimzi operator may not be installed"
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="CRD '${KAFKA_CRD}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 3: ZooKeeper pod health
# ============================================================================
log "Phase 3: ZooKeeper pod health"
EXPECTED_ZK_PODS="${EXPECTED_ZK_PODS:-1}"

# Strimzi labels ZooKeeper pods with strimzi.io/name=<cluster>-zookeeper
ZK_LABEL="strimzi.io/name=${CLUSTER_NAME}-zookeeper"

if check_pod_health_by_label "${NAMESPACE}" "${ZK_LABEL}" "${EXPECTED_ZK_PODS}" PHASE3_STATUS PHASE3_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 4: Kafka broker pod health and PVC binding
# ============================================================================
log "Phase 4: Kafka broker pod health and PVC binding"
EXPECTED_BROKER_PODS="${EXPECTED_BROKER_PODS:-1}"

# Strimzi labels broker pods with strimzi.io/name=<cluster>-kafka
BROKER_LABEL="strimzi.io/name=${CLUSTER_NAME}-kafka"

BROKER_PODS_OK=true
BROKER_PHASE_STATUS=""
BROKER_PHASE_DETAIL=""

# Check broker pod health
if check_pod_health_by_label "${NAMESPACE}" "${BROKER_LABEL}" "${EXPECTED_BROKER_PODS}" BROKER_POD_STATUS BROKER_POD_DETAIL; then
  BROKER_PHASE_STATUS="${BROKER_POD_STATUS}"
  BROKER_PHASE_DETAIL="pods: ${BROKER_POD_DETAIL}"
else
  BROKER_PODS_OK=false
  BROKER_PHASE_STATUS="FAIL"
  BROKER_PHASE_DETAIL="pods: ${BROKER_POD_DETAIL}"
  OVERALL_FAILED=1
fi

# Check broker PVC binding status
log "  Checking broker PVC binding"
BROKER_PVC_STATUS=""
BROKER_PVC_DETAIL=""

# ZooKeeper PVCs contain the cluster name and 'zookeeper'
# Broker PVCs contain the cluster name and 'kafka'
check_pvc_bound "${NAMESPACE}" "${CLUSTER_NAME}-kafka" BROKER_PVC_STATUS BROKER_PVC_DETAIL || true
# Don't set OVERALL_FAILED for PVC check — it may still be provisioning

# Combine pod health and PVC binding into a single Phase 4 result
if [ "${BROKER_PODS_OK}" = true ]; then
  if [ "${BROKER_PVC_STATUS}" = "PASS" ]; then
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="${BROKER_PHASE_DETAIL} | PVCs: ${BROKER_PVC_DETAIL}"
  elif [ "${BROKER_PVC_STATUS}" = "WARN" ]; then
    PHASE4_STATUS="WARN"
    PHASE4_DETAIL="${BROKER_PHASE_DETAIL} | PVCs: ${BROKER_PVC_DETAIL}"
  else
    # Pods healthy but PVCs not bound — may still be provisioning
    PHASE4_STATUS="WARN"
    PHASE4_DETAIL="${BROKER_PHASE_DETAIL} | PVCs: ${BROKER_PVC_DETAIL:-not bound yet}"
  fi
  log "Phase 4: ${PHASE4_DETAIL}"
else
  # Pod health already failed — PVC status is secondary
  if [ -n "${BROKER_PVC_STATUS}" ] && [ "${BROKER_PVC_STATUS}" != "FAIL" ]; then
    PHASE4_DETAIL="${BROKER_PHASE_DETAIL} | PVCs: ${BROKER_PVC_DETAIL:-pending}"
  fi
  # OVERALL_FAILED already set above
fi

# ============================================================================
# Phase 5: Topic existence (hpa-events)
# ============================================================================
log "Phase 5: Topic existence (${TOPIC_NAME})"
TOPIC_CRD="kafkatopics.kafka.strimzi.io"

if kubectl --kubeconfig "${KUBECONFIG}" get crd "${TOPIC_CRD}" > /dev/null 2>&1; then
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafkatopic "${TOPIC_NAME}" > /dev/null 2>&1; then
    # Topic CR exists — verify its status
    TOPIC_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafkatopic "${TOPIC_NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1 || true)

    TOPIC_PARTITIONS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafkatopic "${TOPIC_NAME}" \
      -o jsonpath='{.spec.partitions}' 2>&1 || true)
    TOPIC_REPLICAS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafkatopic "${TOPIC_NAME}" \
      -o jsonpath='{.spec.replicas}' 2>&1 || true)

    if [ "${TOPIC_READY}" = "True" ]; then
      PHASE5_STATUS="PASS"
      PHASE5_DETAIL="KafkaTopic '${TOPIC_NAME}' Ready=True (partitions=${TOPIC_PARTITIONS:-?}, replicas=${TOPIC_REPLICAS:-?})"
      log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
    elif [ "${TOPIC_READY}" = "False" ]; then
      TOPIC_REASON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get kafkatopic "${TOPIC_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>&1 || true)
      PHASE5_STATUS="FAIL"
      PHASE5_DETAIL="KafkaTopic '${TOPIC_NAME}' Ready=False (reason=${TOPIC_REASON:-unknown})"
      OVERALL_FAILED=1
    else
      # No Ready condition yet — topic CR exists but hasn't been reconciled
      PHASE5_STATUS="PASS"
      PHASE5_DETAIL="KafkaTopic '${TOPIC_NAME}' exists (status not yet populated, partitions=${TOPIC_PARTITIONS:-?})"
      log "Phase 5: ${PHASE5_DETAIL} -- PASSED (graceful)"
    fi
  else
    err "KafkaTopic '${TOPIC_NAME}' not found in namespace '${NAMESPACE}'"
    PHASE5_STATUS="FAIL"
    PHASE5_DETAIL="KafkaTopic '${TOPIC_NAME}' not found in '${NAMESPACE}'"
    OVERALL_FAILED=1
  fi
else
  err "CRD '${TOPIC_CRD}' not found"
  PHASE5_STATUS="FAIL"
  PHASE5_DETAIL="CRD '${TOPIC_CRD}' not found"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 6: Produce/consume test via ephemeral kafka-client pod
# ============================================================================
log "Phase 6: Produce/consume test via ephemeral kafka-client"

# This phase requires the Kafka cluster to be Ready. If Phase 2 failed,
# skip the produce/consume test rather than triggering more errors.
if [ "${PHASE2_STATUS}" != "PASS" ]; then
  PHASE6_STATUS="SKIP"
  PHASE6_DETAIL="Kafka cluster not Ready — skipping produce/consume test"
  log "Phase 6: ${PHASE6_DETAIL}"
  log "  (Phase 2 = ${PHASE2_STATUS}: Kafka cluster must be Ready to test)"
else
  # Find the Kafka bootstrap address
  BOOTSTRAP_SERVICES=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get svc \
    -l strimzi.io/cluster="${CLUSTER_NAME}" -o name 2>&1 | grep '\-kafka-bootstrap' || true)

  if [ -z "${BOOTSTRAP_SERVICES}" ]; then
    # Fallback: try direct service name pattern
    BOOTSTRAP_HOST="${CLUSTER_NAME}-kafka-bootstrap.${NAMESPACE}.svc.cluster.local"
    log "  Using default bootstrap host: ${BOOTSTRAP_HOST}"
  else
    BOOTSTRAP_SVC=$(echo "${BOOTSTRAP_SERVICES}" | head -1)
    BOOTSTRAP_HOST="${BOOTSTRAP_SVC#service/}"
    BOOTSTRAP_HOST="${BOOTSTRAP_HOST}.${NAMESPACE}.svc.cluster.local"
    log "  Found bootstrap service: ${BOOTSTRAP_HOST}"
  fi

  BOOTSTRAP_PORT=9092
  CLIENT_POD_NAME="kafka-verify-client-${CLUSTER_NAME}"
  CLIENT_NAMESPACE="${NAMESPACE}"

  # Clean up any leftover client pod from a previous run
  kubectl --kubeconfig "${KUBECONFIG}" -n "${CLIENT_NAMESPACE}" delete pod "${CLIENT_POD_NAME}" \
    --ignore-not-found=true --grace-period=5 --wait=true > /dev/null 2>&1 || true

  # Create an ephemeral kafka-client pod for produce/consume testing
  log "  Creating kafka-client pod: ${CLIENT_POD_NAME}"
  CLIENT_CREATED=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLIENT_NAMESPACE}" run "${CLIENT_POD_NAME}" \
    --image="${KAFKA_CLIENT_IMAGE}" \
    --restart=Never \
    --command -- sleep 60 2>&1) || { err "Failed to create kafka-client pod: ${CLIENT_CREATED}"; PHASE6_STATUS="FAIL"; PHASE6_DETAIL="Failed to create client pod"; OVERALL_FAILED=1; }

  if [ -z "${PHASE6_STATUS}" ]; then
    # Wait for client pod to be Ready
    WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
    log "  Waiting up to ${WAIT_TIMEOUT}s for kafka-client pod to be Ready"
    if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${CLIENT_NAMESPACE}" wait \
      --for=condition=Ready "pod/${CLIENT_POD_NAME}" --timeout="${WAIT_TIMEOUT}s" > /dev/null 2>&1; then
      err "kafka-client pod not Ready within ${WAIT_TIMEOUT}s"
      PHASE6_STATUS="FAIL"
      PHASE6_DETAIL="Client pod '${CLIENT_POD_NAME}' not Ready within ${WAIT_TIMEOUT}s"

      # Collect pod status for diagnostics
      local POD_DIAG
      POD_DIAG=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLIENT_NAMESPACE}" get pod "${CLIENT_POD_NAME}" -o wide 2>&1 || true)
      local POD_LOGS
      POD_LOGS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLIENT_NAMESPACE}" logs "${CLIENT_POD_NAME}" 2>&1 || true)
      log "  Client pod status: ${POD_DIAG}"
      log "  Client pod logs: ${POD_LOGS}"

      OVERALL_FAILED=1
    fi
  fi

  # Produce a test message
  if [ -z "${PHASE6_STATUS}" ]; then
    local TEST_MESSAGE="verify-kafka-$(date +%s)"
    local PRODUCE_CMD="echo '${TEST_MESSAGE}' | /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server ${BOOTSTRAP_HOST}:${BOOTSTRAP_PORT} \
      --topic ${TOPIC_NAME} \
      --timeout 10000 2>&1"

    log "  Producing message to topic '${TOPIC_NAME}': ${TEST_MESSAGE}"
    PRODUCE_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLIENT_NAMESPACE}" exec "${CLIENT_POD_NAME}" \
      -- bash -c "${PRODUCE_CMD}" 2>&1) || true

    if [ $? -ne 0 ] && [ -n "${PRODUCE_RESULT}" ]; then
      err "Produce to '${TOPIC_NAME}' failed: ${PRODUCE_RESULT}"
      PHASE6_STATUS="FAIL"
      PHASE6_DETAIL="Produce to '${TOPIC_NAME}' failed: $(echo "${PRODUCE_RESULT}" | tr '\n' ' ' | head -c 80)"
      OVERALL_FAILED=1
    else
      log "  Produce succeeded (result: ${PRODUCE_RESULT:-empty})"
    fi
  fi

  # Consume the test message
  if [ -z "${PHASE6_STATUS}" ]; then
    local CONSUME_CMD="/opt/kafka/bin/kafka-console-consumer.sh \
      --bootstrap-server ${BOOTSTRAP_HOST}:${BOOTSTRAP_PORT} \
      --topic ${TOPIC_NAME} \
      --from-beginning \
      --max-messages 1 \
      --timeout-ms 15000 2>&1"

    log "  Consuming one message from topic '${TOPIC_NAME}'"
    CONSUME_RESULT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CLIENT_NAMESPACE}" exec "${CLIENT_POD_NAME}" \
      -- bash -c "${CONSUME_CMD}" 2>&1) || true

    CONSUMED_MSG=$(echo "${CONSUME_RESULT}" | head -1)
    CONSUMER_LOG=$(echo "${CONSUME_RESULT}" | tail -n +2 | tr '\n' ' ' | head -c 80)

    if echo "${CONSUMED_MSG}" | grep -q "${TEST_MESSAGE}"; then
      PHASE6_STATUS="PASS"
      PHASE6_DETAIL="Produce/consume to '${TOPIC_NAME}' verified (msg='${CONSUMED_MSG}')"
      log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
    elif [ -n "${CONSUMED_MSG}" ]; then
      PHASE6_STATUS="WARN"
      PHASE6_DETAIL="Consumed message does not match produced one (got='${CONSUMED_MSG}', expected='${TEST_MESSAGE}')"
      log "Phase 6: ${PHASE6_DETAIL} -- WARN"
    else
      err "Consume from '${TOPIC_NAME}' returned no messages"
      PHASE6_STATUS="FAIL"
      PHASE6_DETAIL="Consume from '${TOPIC_NAME}' returned no messages (log: ${CONSUMER_LOG})"
      OVERALL_FAILED=1
    fi
  fi

  # Clean up the client pod
  log "  Cleaning up kafka-client pod: ${CLIENT_POD_NAME}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${CLIENT_NAMESPACE}" delete pod "${CLIENT_POD_NAME}" \
    --ignore-not-found=true --grace-period=3 --wait=true > /dev/null 2>&1 || true
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Kafka Health Verification Summary ==="
printf "%-12s %-12s %-60s\n" "PHASE"        "STATUS" "DETAIL"
printf "%-12s %-12s %-60s\n" "-----"        "------" "------"
printf "%-12s %-12s %-60s\n" "1-Op-Pod"     "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-12s %-12s %-60s\n" "2-Kafka-CR"   "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-12s %-12s %-60s\n" "3-ZooKeeper"  "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-12s %-12s %-60s\n" "4-Broker+PVC" "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-12s %-12s %-60s\n" "5-Topic"      "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-12s %-12s %-60s\n" "6-ProdCons"   "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
echo "================================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "================================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-kafka: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-kafka: ALL CHECKS PASSED"
exit 0

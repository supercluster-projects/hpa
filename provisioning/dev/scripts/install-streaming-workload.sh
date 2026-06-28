#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-streaming-workload.sh — Deploy SpinApp stream workload
#
# Deploys the stream SpinApp on a Kubernetes cluster by:
#   1. Pre-flight check: Kafka cluster (hpa-kafka) is Ready via Strimzi CR
#   2. Pre-flight check: KeyDB deployment is available
#   3. Apply SpinApp 'stream' via Kustomize overlay (or direct apply)
#   4. Wait for SpinApp 'stream' to become Ready
#
# The Kustomize overlay at --gitops-overlay-path should contain the
# stream.yaml SpinApp manifest (under spins/ directory).
#
# Idempotent: safe to re-run on an already-configured cluster (kubectl apply
# is used throughout, waits are conditional).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-streaming-workload.sh [--kubeconfig <path>]
#                                        [--gitops-overlay-path <path>]
#                                        [--workloads-namespace <ns>]
#                                        [--kafka-namespace <ns>]
#                                        [--kafka-cluster-name <name>]
#                                        [--keydb-namespace <ns>]
#                                        [--wait-timeout <duration>]
#                                        [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env DEV_WORKLOADS_NAMESPACE
require_env DEV_GITOPS_OVERLAY_PATH

# ---- Internal defaults (script-internal only) -------------------------
WORKLOADS_NAMESPACE="${DEV_WORKLOADS_NAMESPACE}"
GITOPS_OVERLAY_PATH="${DEV_GITOPS_OVERLAY_PATH}"
KAFKA_NAMESPACE="strimzi"
KAFKA_CLUSTER_NAME="hpa-kafka"
KEYDB_NAMESPACE="keydb"
WAIT_TIMEOUT=600

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)               KUBECONFIG="$2";                shift 2 ;;
    --gitops-overlay-path)      GITOPS_OVERLAY_PATH="$2";       shift 2 ;;
    --workloads-namespace)      WORKLOADS_NAMESPACE="$2";       shift 2 ;;
    --kafka-namespace)          KAFKA_NAMESPACE="$2";           shift 2 ;;
    --kafka-cluster-name)       KAFKA_CLUSTER_NAME="$2";        shift 2 ;;
    --keydb-namespace)          KEYDB_NAMESPACE="$2";           shift 2 ;;
    --wait-timeout)             WAIT_TIMEOUT="$2";              shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy stream SpinApp workload with pre-flight dependency checks.

Steps:
  1  Pre-flight: verify Kafka cluster 'hpa-kafka' is Ready
  2  Pre-flight: verify KeyDB deployment is available
  3  Apply SpinApp 'stream' via Kustomize overlay
  4  Wait for SpinApp 'stream' to become Ready

Options:
  --kubeconfig PATH              Path to kubeconfig (default: ../opentofu/kubeconfig)
  --gitops-overlay-path PATH     Kustomize overlay directory (default: ../../../gitops-workloads/functions/overlays/dev)
  --workloads-namespace NS       Target namespace for the SpinApp (default: hpa-workloads)
  --kafka-namespace NS           Strimzi/Kafka namespace (default: strimzi)
  --kafka-cluster-name NAME      Kafka CR name (default: hpa-kafka)
  --keydb-namespace NS           KeyDB namespace (default: keydb)
  --wait-timeout DUR             Timeout for kubectl rollout and condition waits (default: 10m)
  --help, -h                     Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-streaming-workload: starting"
log "  kubeconfig:            ${KUBECONFIG}"
log "  gitops overlay path:   ${GITOPS_OVERLAY_PATH}"
log "  workloads namespace:   ${WORKLOADS_NAMESPACE}"
log "  kafka namespace:       ${KAFKA_NAMESPACE}"
log "  kafka cluster name:    ${KAFKA_CLUSTER_NAME}"
log "  keydb namespace:       ${KEYDB_NAMESPACE}"
log "  wait timeout:          ${WAIT_TIMEOUT}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Internal state tracking ----------------------------------------------
KAFKA_READY=false
KEYDB_AVAILABLE=false
STREAM_PROCESSOR_APPLIED=false

# ============================================================================
# Step 1: Pre-flight — verify Kafka cluster is Ready
# ============================================================================
log "Step 1: Pre-flight check — Kafka cluster '${KAFKA_CLUSTER_NAME}'"

if ! kubectl --kubeconfig "${KUBECONFIG}" get crd kafkas.kafka.strimzi.io > /dev/null 2>&1; then
  die "Strimzi CRD 'kafkas.kafka.strimzi.io' not found — is the Strimzi operator installed?"
fi

if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get kafka "${KAFKA_CLUSTER_NAME}" > /dev/null 2>&1; then
  die "Kafka CR '${KAFKA_CLUSTER_NAME}' not found in namespace '${KAFKA_NAMESPACE}' — install-kafka.sh must run first"
fi

KAFKA_STATUS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get kafka "${KAFKA_CLUSTER_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

if [ "${KAFKA_STATUS}" = "True" ]; then
  KAFKA_READY=true
  log "  Kafka cluster '${KAFKA_CLUSTER_NAME}': READY"
else
  # Check if the cluster is still provisioning (no condition yet)
  KAFKA_STATE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get kafka "${KAFKA_CLUSTER_NAME}" \
    -o jsonpath='{.status.kafka.state}' 2>/dev/null || echo "")
  if [ -n "${KAFKA_STATE}" ]; then
    die "Kafka cluster '${KAFKA_CLUSTER_NAME}' is in state '${KAFKA_STATE}', expected Ready. Wait for install-kafka.sh to complete."
  else
    die "Kafka cluster '${KAFKA_CLUSTER_NAME}' condition=Ready=${KAFKA_STATUS}. The Kafka cluster may still be provisioning."
  fi
fi

# Also verify the kafka bootstrap service is available
if kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get svc "${KAFKA_CLUSTER_NAME}-kafka-bootstrap" > /dev/null 2>&1; then
  log "  Kafka bootstrap service '${KAFKA_CLUSTER_NAME}-kafka-bootstrap': FOUND"
else
  die "Kafka bootstrap service '${KAFKA_CLUSTER_NAME}-kafka-bootstrap' not found in namespace '${KAFKA_NAMESPACE}'"
fi

# ============================================================================
# Step 2: Pre-flight — verify KeyDB deployment is available
# ============================================================================
log "Step 2: Pre-flight check — KeyDB deployment"

if ! kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get deployment keydb > /dev/null 2>&1; then
  die "KeyDB deployment not found in namespace '${KEYDB_NAMESPACE}' — install-runtimes.sh must run first"
fi

# Check that KeyDB has at least one ready replica
KEYDB_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get deployment keydb \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [ "${KEYDB_READY}" -gt 0 ]; then
  KEYDB_AVAILABLE=true
  log "  KeyDB: AVAILABLE (readyReplicas=${KEYDB_READY})"
else
  # Wait briefly for KeyDB to become ready
  log "  KeyDB has 0 ready replicas, waiting up to ${WAIT_TIMEOUT}s..."
  if kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" rollout status deployment/keydb \
    --timeout="${WAIT_TIMEOUT}" > /dev/null 2>&1; then
    KEYDB_AVAILABLE=true
    log "  KeyDB: AVAILABLE (after rollout wait)"
  else
    die "KeyDB deployment not ready within ${WAIT_TIMEOUT}s — install-runtimes.sh may still be in progress"
  fi
fi

# Also verify the KeyDB service DNS is resolvable (cluster-internal)
if kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get svc keydb > /dev/null 2>&1; then
  log "  KeyDB service 'keydb.${KEYDB_NAMESPACE}.svc.cluster.local:6379': FOUND"
else
  die "KeyDB service not found in namespace '${KEYDB_NAMESPACE}'"
fi

log "  All pre-flight checks passed. Proceeding with SpinApp deployment."

# ============================================================================
# Step 3: Apply SpinApp 'stream' via Kustomize overlay
# ============================================================================
log "Step 3: Applying SpinApp 'stream'"

# Ensure the workloads namespace exists
kubectl create namespace "${WORKLOADS_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${WORKLOADS_NAMESPACE}'"
log "  Namespace '${WORKLOADS_NAMESPACE}': READY"

# Determine the full path to the Kustomize overlay
GITOPS_ABS_PATH=""
if [ -d "${GITOPS_OVERLAY_PATH}" ]; then
  # Already an absolute or relative path from cwd
  GITOPS_ABS_PATH="$(cd "${GITOPS_OVERLAY_PATH}" 2>/dev/null && pwd)" || true
fi
if [ -z "${GITOPS_ABS_PATH}" ]; then
  # Try relative to PROJECT_ROOT
  GITOPS_ABS_PATH="$(cd "${PROJECT_ROOT}/${GITOPS_OVERLAY_PATH}" 2>/dev/null && pwd)" || true
fi

# Try to apply via Kustomize first
KUSTOMIZE_OK=false
if [ -n "${GITOPS_ABS_PATH}" ] && [ -f "${GITOPS_ABS_PATH}/kustomization.yaml" ]; then
  log "  Using Kustomize overlay at '${GITOPS_ABS_PATH}'"

  # Check if stream is a resource in the spins kustomization
  SPINS_KUSTOMIZE="${GITOPS_ABS_PATH}/spins/kustomization.yaml"
  if [ -f "${SPINS_KUSTOMIZE}" ] && (grep -q 'stream\.yaml' "${SPINS_KUSTOMIZE}" 2>/dev/null || grep -q stream "${SPINS_KUSTOMIZE}" 2>/dev/null); then
    # Build and apply the spins sub-overlay
    if command -v kustomize >/dev/null 2>&1; then
      SPINS_BUILD=$(kustomize build "${GITOPS_ABS_PATH}/spins" 2>/dev/null) && \
        echo "${SPINS_BUILD}" | kubectl apply -f - > /dev/null 2>&1 && \
        KUSTOMIZE_OK=true
    elif kubectl kustomize "${GITOPS_ABS_PATH}/spins" > /dev/null 2>&1; then
      kubectl kustomize "${GITOPS_ABS_PATH}/spins" | kubectl apply -f - > /dev/null 2>&1 && \
        KUSTOMIZE_OK=true
    fi
    if [ "${KUSTOMIZE_OK}" = true ]; then
      log "  Kustomize overlay (spins/): APPLIED"
    fi
  fi

  # Fallback: try the full overlay
  if [ "${KUSTOMIZE_OK}" != true ]; then
    log "  stream.yaml not found in spins kustomization, trying full overlay..."
    if command -v kustomize >/dev/null 2>&1; then
      FULL_BUILD=$(kustomize build "${GITOPS_ABS_PATH}" 2>/dev/null) && \
        echo "${FULL_BUILD}" | kubectl apply -f - > /dev/null 2>&1 && \
        KUSTOMIZE_OK=true
    elif kubectl kustomize "${GITOPS_ABS_PATH}" > /dev/null 2>&1; then
      kubectl kustomize "${GITOPS_ABS_PATH}" | kubectl apply -f - > /dev/null 2>&1 && \
        KUSTOMIZE_OK=true
    fi
    if [ "${KUSTOMIZE_OK}" = true ]; then
      log "  Full Kustomize overlay: APPLIED"
    fi
  fi
fi

# Fallback: apply the stream manifest directly
if [ "${KUSTOMIZE_OK}" != true ]; then
  log "  Kustomize not available or stream.yaml not in overlay, applying manifest directly..."


  # Try to find the stream.yaml manifest
  STREAM_MANIFEST=""
  for candidate in \
    "${GITOPS_ABS_PATH}/spins/stream.yaml" \
    "${GITOPS_OVERLAY_PATH}/spins/stream.yaml" \
    "${PROJECT_ROOT}/gitops-workloads/functions/overlays/dev/spins/stream.yaml"; do
    if [ -f "${candidate}" ]; then
      STREAM_MANIFEST="${candidate}"
      break
    fi
  done

  if [ -n "${STREAM_MANIFEST}" ]; then
    kubectl apply -f "${STREAM_MANIFEST}" > /dev/null 2>&1 \
      || die "Failed to apply stream manifest from '${STREAM_MANIFEST}'"
    log "  Manifest '${STREAM_MANIFEST}': APPLIED"
    KUSTOMIZE_OK=true
  else
    die "Could not find stream.yaml manifest. Ensure it exists in the gitops overlay path."
  fi
fi

# Verify the SpinApp CR was created
if kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream > /dev/null 2>&1; then
  STREAM_PROCESSOR_APPLIED=true
  log "  SpinApp 'stream': APPLIED"
else
  die "SpinApp 'stream' not found after apply"
fi

# ============================================================================
# Step 4: Wait for SpinApp 'stream' to become Ready
# ============================================================================
log "Step 4: Waiting for SpinApp 'stream' to become Ready"

STREAM_STATUS="NOT READY"
if [ "${STREAM_PROCESSOR_APPLIED}" = true ]; then
  # SpinApp uses conditions similar to Knative. Check Ready condition.
  SPINAPP_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

  if [ "${SPINAPP_READY}" = "True" ]; then
    STREAM_STATUS="Ready"
    log "  SpinApp 'stream': READY"
  elif [ "${SPINAPP_READY}" = "Unknown" ]; then
    SPINAPP_REASON=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")
    log "  SpinApp 'stream' progressing: condition=${SPINAPP_READY}, reason=${SPINAPP_REASON}"
    STREAM_STATUS="Progressing (${SPINAPP_REASON})"

    # Check if the underlying deployment exists and is ready
    if kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get deployment stream > /dev/null 2>&1; then
      kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" rollout status deployment/stream \
        --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 && \
        log "  Deployment 'stream': ROLLOUT COMPLETE" || \
        log "  (non-fatal) Deployment 'stream' rollout did not complete within ${WAIT_TIMEOUT}"
    fi
  else
    err "SpinApp 'stream' not Ready: condition=${SPINAPP_READY}"
    STREAM_STATUS="Failed (${SPINAPP_READY})"
  fi
fi

# ============================================================================
# Step 5: Gather component statuses for summary
# ============================================================================
log "Step 5: Gathering component statuses"

# SpinApp detailed status
SPINAPP_DETAIL="NOT FOUND"
if kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream > /dev/null 2>&1; then
  SPINAPP_RDY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  SPINAPP_REPLICAS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "N/A")
  SPINAPP_RDY_REPLICAS=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${WORKLOADS_NAMESPACE}" get spinapp stream \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "N/A")
  SPINAPP_DETAIL="Ready=${SPINAPP_RDY}, replicas=${SPINAPP_REPLICAS}, ready=${SPINAPP_RDY_REPLICAS}"
fi

# Kafka topic status
TOPIC_STATUS="NOT CHECKED"
if kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get kafkatopic hpa-events > /dev/null 2>&1; then
  TOPIC_READY=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KAFKA_NAMESPACE}" get kafkatopic hpa-events \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  TOPIC_STATUS="Ready=${TOPIC_READY}"
fi

# KeyDB status
KEYDB_DETAIL=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${KEYDB_NAMESPACE}" get deployment keydb \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Streaming Workload Installation Summary ==="
echo "  Namespace:"
echo "    name:               ${WORKLOADS_NAMESPACE}"
echo ""
echo "  Dependencies:"
echo "    Kafka cluster:      ${KAFKA_READY}"
echo "    Kafka namespace:    ${KAFKA_NAMESPACE}"
echo "    Kafka bootstrap:    ${KAFKA_CLUSTER_NAME}-kafka-bootstrap.${KAFKA_NAMESPACE}.svc.cluster.local:9092"
echo "    Topic hpa-events:   ${TOPIC_STATUS}"
echo "    KeyDB available:    ${KEYDB_AVAILABLE} (readyReplicas: ${KEYDB_DETAIL})"
echo "    KeyDB endpoint:     keydb.${KEYDB_NAMESPACE}.svc.cluster.local:6379"
echo ""
echo "  SpinApp:"
echo "    name:               stream"
echo "    namespace:          ${WORKLOADS_NAMESPACE}"
echo "    status:             ${STREAM_STATUS}"
echo "    detail:             ${SPINAPP_DETAIL}"
echo ""
echo "  Pipeline:"
echo "    Kafka -> SpinKube -> KeyDB"
echo "    Topic: hpa-events"
echo "    Consumer group: hpa-stream"
echo "    KeyDB counter keys: device_count:<device_type>"
echo ""
echo "  Pods in workload namespace:"
kubectl -n "${WORKLOADS_NAMESPACE}" get pods --no-headers 2>/dev/null \
  | awk '{printf "    %-40s %-10s %-10s %s\n", $1, $2, $3, $4}' \
  || echo "    (no pods in namespace)"
echo ""
echo "============================================="

log "install-streaming-workload: completed successfully"
exit 0

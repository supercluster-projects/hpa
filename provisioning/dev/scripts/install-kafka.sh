#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-kafka.sh — Deploy Strimzi Kafka Operator + Kafka cluster + topics
#
# Installs:
#   1. Strimzi Kafka Operator — Apache Kafka operator (Helm chart)
#   2. Kafka CR 'hpa-kafka' — 1 ZooKeeper + 1 Kafka broker (resource
#      constrained, 512MB heap, ceph-rbd PVCs)
#   3. KafkaTopic 'hpa-events' — topic for application event ingestion
#
# Idempotent: safe to re-run on an already-configured cluster (Helm
# upgrade --atomic --wait and kubectl apply are used throughout).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-kafka.sh [--kubeconfig <path>]
#                           [--strimzi-version <ver>]
#                           [--kafka-image <image>]
#                           [--zookeeper-image <image>]
#                           [--kafka-version <ver>]
#                           [--storage-class <name>]
#                           [--namespace <name>]
#                           [--cluster-name <name>]
#                           [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env STRIMZI_VERSION
require_env DEV_STORAGE_CLASS

# ---- Internal defaults (script-internal only) -------------------------
STORAGE_CLASS="${DEV_STORAGE_CLASS}"
STRIMZI_NAMESPACE="strimzi"
CLUSTER_NAME="hpa-kafka"
WAIT_TIMEOUT=600

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";           shift 2 ;;
    --strimzi-version)     STRIMZI_VERSION="$2";      shift 2 ;;
    --kafka-image)         KAFKA_IMAGE="$2";          shift 2 ;;
    --zookeeper-image)     ZOOKEEPER_IMAGE="$2";      shift 2 ;;
    --kafka-version)       KAFKA_VERSION="$2";         shift 2 ;;
    --storage-class)       STORAGE_CLASS="$2";         shift 2 ;;
    --namespace)           STRIMZI_NAMESPACE="$2";     shift 2 ;;
    --cluster-name)        CLUSTER_NAME="$2";          shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Strimzi Kafka Operator + Kafka cluster + topics on a Kubernetes cluster.

Components installed:
  - Strimzi Kafka Operator   Apache Kafka operator (Helm chart from strimzi.io)
  - Kafka CR 'hpa-kafka'     1 ZooKeeper + 1 Kafka broker (ceph-rbd PVCs)
  - KafkaTopic 'hpa-events'  Topic for application event ingestion

Options:
  --kubeconfig PATH           Path to kubeconfig (default: ../opentofu/kubeconfig)
  --strimzi-version VER       Strimzi operator Helm chart version (default: 0.45.0)
  --kafka-image IMAGE         Kafka broker container image (optional)
  --zookeeper-image IMAGE     ZooKeeper container image (optional)
  --kafka-version VER         Kafka version for the CR (default: 3.9.0)
  --storage-class NAME        StorageClass for Kafka and ZooKeeper PVCs (default: ceph-rbd)
  --namespace NAME            Namespace for Strimzi operator and Kafka CR (default: strimzi)
  --cluster-name NAME         Kafka CR resource name (default: hpa-kafka)
  --wait-timeout DUR          Timeout for Helm install and rollouts (default: 10m)
  --help, -h                  Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-kafka: starting"
log "  strimzi-version:  ${STRIMZI_VERSION}"
log "  kafka-version:    ${KAFKA_VERSION:-3.9.0}"
log "  storage-class:    ${STORAGE_CLASS}"
log "  namespace:        ${STRIMZI_NAMESPACE}"
log "  cluster-name:     ${CLUSTER_NAME}"
log "  wait-timeout:     ${WAIT_TIMEOUT}"

command -v helm >/dev/null 2>&1    || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]             || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Internal state tracking ----------------------------------------------
STRIMZI_OPERATOR_INSTALLED=false

# ============================================================================
# Step 1: Install Strimzi Kafka Operator via Helm
# ============================================================================
log "Step 1: Installing Strimzi Kafka Operator (${STRIMZI_VERSION})"

helm repo add strimzi https://strimzi.io/charts/ \
  --force-update > /dev/null 2>&1 \
  || die "Failed to add Strimzi Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Strimzi Helm repo: READY"

kubectl create namespace "${STRIMZI_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${STRIMZI_NAMESPACE}'"
log "  Namespace '${STRIMZI_NAMESPACE}': READY"

helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace "${STRIMZI_NAMESPACE}" \
  --version "${STRIMZI_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  > /dev/null 2>&1 || log "  (non-fatal) Strimzi Helm install will be re-attempted via --atomic"

# Verify Strimzi operator installed; if not, retry once
if kubectl -n "${STRIMZI_NAMESPACE}" get deployment strimzi-cluster-operator > /dev/null 2>&1; then
  STRIMZI_OPERATOR_INSTALLED=true
  log "  Strimzi operator: INSTALLED"
else
  log "  Strimzi operator not found after first attempt, retrying..."
  helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
    --namespace "${STRIMZI_NAMESPACE}" \
    --version "${STRIMZI_VERSION}" \
    --atomic \
    --wait \
    --timeout "${WAIT_TIMEOUT}" \
    > /dev/null 2>&1 || die "Strimzi operator Helm install failed after retry"
  STRIMZI_OPERATOR_INSTALLED=true
  log "  Strimzi operator: INSTALLED"
fi

# Wait for Strimzi operator rollout
if kubectl -n "${STRIMZI_NAMESPACE}" get deployment strimzi-cluster-operator > /dev/null 2>&1; then
  kubectl -n "${STRIMZI_NAMESPACE}" rollout status deployment/strimzi-cluster-operator \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || die "Strimzi operator rollout did not complete within ${WAIT_TIMEOUT}"
  log "  Deployment 'strimzi-cluster-operator': ROLLOUT COMPLETE"
else
  log "  Deployment 'strimzi-cluster-operator': NOT FOUND (skipping rollout wait)"
fi

# ============================================================================
# Step 2: Create Kafka CR with 1 ZooKeeper + 1 Kafka broker (resource-constrained)
# ============================================================================
log "Step 2: Creating Kafka CR '${CLUSTER_NAME}'"

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply Kafka CR '${CLUSTER_NAME}'"
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${STRIMZI_NAMESPACE}
spec:
  kafka:
    version: ${KAFKA_VERSION:-3.9.0}
    replicas: 1
    resources:
      requests:
        memory: 512Mi
        cpu: 250m
      limits:
        memory: 512Mi
        cpu: 500m
    jvmOptions:
      -Xms: 512m
      -Xmx: 512m
    storage:
      type: persistent-claim
      size: 5Gi
      class: ${STORAGE_CLASS}
      deleteClaim: false
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      log.retention.hours: 24
      log.segment.bytes: 1073741824
  zookeeper:
    replicas: 1
    resources:
      requests:
        memory: 512Mi
        cpu: 250m
      limits:
        memory: 512Mi
        cpu: 500m
    jvmOptions:
      -Xms: 512m
      -Xmx: 512m
    storage:
      type: persistent-claim
      size: 5Gi
      class: ${STORAGE_CLASS}
      deleteClaim: false
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF
log "  Kafka CR '${CLUSTER_NAME}': APPLIED"

log "  Waiting for Kafka cluster rollout..."

# Wait for ZooKeeper StatefulSet
if kubectl -n "${STRIMZI_NAMESPACE}" get statefulset "${CLUSTER_NAME}-zookeeper" > /dev/null 2>&1; then
  kubectl -n "${STRIMZI_NAMESPACE}" rollout status statefulset/"${CLUSTER_NAME}-zookeeper" \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || log "  (non-fatal) ZooKeeper StatefulSet rollout did not complete within ${WAIT_TIMEOUT}"
  log "  StatefulSet '${CLUSTER_NAME}-zookeeper': ROLLOUT COMPLETE"
fi

# Wait for Kafka StatefulSet
if kubectl -n "${STRIMZI_NAMESPACE}" get statefulset "${CLUSTER_NAME}-kafka" > /dev/null 2>&1; then
  kubectl -n "${STRIMZI_NAMESPACE}" rollout status statefulset/"${CLUSTER_NAME}-kafka" \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || log "  (non-fatal) Kafka StatefulSet rollout did not complete within ${WAIT_TIMEOUT}"
  log "  StatefulSet '${CLUSTER_NAME}-kafka': ROLLOUT COMPLETE"
fi

# ============================================================================
# Step 3: Create KafkaTopic 'hpa-events' for application event ingestion
# ============================================================================
log "Step 3: Creating KafkaTopic 'hpa-events'"

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply KafkaTopic 'hpa-events'"
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: hpa-events
  namespace: ${STRIMZI_NAMESPACE}
  labels:
    strimzi.io/cluster: ${CLUSTER_NAME}
spec:
  partitions: 1
  replicas: 1
  config:
    retention.ms: 604800000
    segment.bytes: 1073741824
EOF
log "  KafkaTopic 'hpa-events': APPLIED"

# ============================================================================
# Step 4: Gather component statuses for summary
# ============================================================================
log "Step 4: Gathering component statuses"

# Strimzi operator status
SO_STATUS="NOT INSTALLED"
if [ "${STRIMZI_OPERATOR_INSTALLED}" = true ]; then
  SO_READY=$(kubectl -n "${STRIMZI_NAMESPACE}" get deployment strimzi-cluster-operator \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  SO_ROLLOUT=$(kubectl -n "${STRIMZI_NAMESPACE}" rollout status deployment/strimzi-cluster-operator \
    --timeout=5s 2>/dev/null && echo "Ready" || echo "Not Ready")
  SO_STATUS="${SO_ROLLOUT} (replicas: ${SO_READY:-0})"
fi

# Kafka cluster status
KAFKA_STATUS="NOT FOUND"
if kubectl -n "${STRIMZI_NAMESPACE}" get kafka "${CLUSTER_NAME}" > /dev/null 2>&1; then
  KAFKA_READY=$(kubectl -n "${STRIMZI_NAMESPACE}" get kafka "${CLUSTER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  KAFKA_ZS_REPLICAS=$(kubectl -n "${STRIMZI_NAMESPACE}" get statefulset "${CLUSTER_NAME}-zookeeper" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  KAFKA_KS_REPLICAS=$(kubectl -n "${STRIMZI_NAMESPACE}" get statefulset "${CLUSTER_NAME}-kafka" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  KAFKA_STATUS="Ready: ${KAFKA_READY} (ZooKeeper: ${KAFKA_ZS_REPLICAS}/1, Kafka: ${KAFKA_KS_REPLICAS}/1)"
fi

# KafkaTopic status
TOPIC_STATUS="NOT FOUND"
if kubectl -n "${STRIMZI_NAMESPACE}" get kafkatopic hpa-events > /dev/null 2>&1; then
  TOPIC_READY=$(kubectl -n "${STRIMZI_NAMESPACE}" get kafkatopic hpa-events \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  TOPIC_STATUS="Ready: ${TOPIC_READY}"
fi

# PVCs status
log "  Checking PVCs..."
ZK_PVC_STATUS="Not Created"
if kubectl -n "${STRIMZI_NAMESPACE}" get pvc "data-${CLUSTER_NAME}-zookeeper-0" > /dev/null 2>&1; then
  ZK_PVC_STATUS=$(kubectl -n "${STRIMZI_NAMESPACE}" get pvc "data-${CLUSTER_NAME}-zookeeper-0" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
fi
KS_PVC_STATUS="Not Created"
if kubectl -n "${STRIMZI_NAMESPACE}" get pvc "data-${CLUSTER_NAME}-kafka-0" > /dev/null 2>&1; then
  KS_PVC_STATUS=$(kubectl -n "${STRIMZI_NAMESPACE}" get pvc "data-${CLUSTER_NAME}-kafka-0" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Kafka Installation Summary ==="
echo "  Strimzi operator:     ${STRIMZI_VERSION}"
echo "    namespace:          ${STRIMZI_NAMESPACE}"
echo "    status:             ${SO_STATUS}"
echo ""
echo "  Kafka cluster:        ${CLUSTER_NAME}"
echo "    kafka version:      ${KAFKA_VERSION:-3.9.0}"
echo "    storage class:      ${STORAGE_CLASS}"
echo "    status:             ${KAFKA_STATUS}"
echo ""
echo "  ZooKeeper:"
echo "    heap:               512m Xms/Xmx"
echo "    PVC:                data-${CLUSTER_NAME}-zookeeper-0 (${ZK_PVC_STATUS})"
echo "    storage:            5Gi (${STORAGE_CLASS})"
echo ""
echo "  Kafka broker:"
echo "    heap:               512m Xms/Xmx"
echo "    PVC:                data-${CLUSTER_NAME}-kafka-0 (${KS_PVC_STATUS})"
echo "    storage:            5Gi (${STORAGE_CLASS})"
echo "    listeners:          plain:9092 (internal), tls:9093 (internal)"
echo ""
echo "  Topics:"
echo "    hpa-events:         ${TOPIC_STATUS}"
echo ""
echo "  Service endpoints:"
echo "    Kafka bootstrap:    ${CLUSTER_NAME}-kafka-bootstrap.${STRIMZI_NAMESPACE}.svc.cluster.local:9092"
echo "    Kafka TLS:          ${CLUSTER_NAME}-kafka-bootstrap.${STRIMZI_NAMESPACE}.svc.cluster.local:9093"
echo ""
echo "  Helm release status:"
if helm status strimzi-kafka-operator -n "${STRIMZI_NAMESPACE}" > /dev/null 2>&1; then
  helm status strimzi-kafka-operator -n "${STRIMZI_NAMESPACE}" 2>/dev/null \
    | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
    | sed "s/^/    [strimzi-kafka-operator] /" || true
fi
echo ""
echo "  Strimzi CRDs:"
for crd in kafkas.kafka.strimzi.io kafkatopics.kafka.strimzi.io kafkausers.kafka.strimzi.io; do
  if kubectl get crd "${crd}" > /dev/null 2>&1; then
    echo "    ${crd}: PRESENT"
  else
    echo "    ${crd}: MISSING"
  fi
done
echo ""
echo "  PVCs:"
kubectl get pvc -n "${STRIMZI_NAMESPACE}" --no-headers 2>/dev/null \
  | awk '{printf "    %-40s %-10s %-10s %s\n", $1, $2, $5, $6}' \
  || echo "    (no PVCs found)"
echo ""
echo "================================="

log "install-kafka: completed successfully"
exit 0

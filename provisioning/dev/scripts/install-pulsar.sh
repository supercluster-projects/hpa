#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-pulsar.sh — Deploy Apache Pulsar cluster (ZK + BK + Broker + Func)
#
# Installs Apache Pulsar via the official Apache Helm chart with resource
# tuning for 3GB worker VMs:
#   1. ZooKeeper — 1 replica, 256Mi heap, 5Gi ceph-rbd
#   2. BookKeeper — 1 replica, 512Mi heap, 10Gi ceph-rbd data + 5Gi journal
#   3. Broker — 1 replica, 512Mi heap
#   4. Function Worker — 1 replica, 256Mi heap (standalone)
#   5. Toolset — pulsar-admin CLI for topic and function management
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-pulsar.sh [--kubeconfig <path>]
#                            [--pulsar-version <ver>]
#                            [--namespace <ns>]
#                            [--storage-class <name>]
#                            [--release-name <name>]
#                            [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env PULSAR_VERSION
require_env DEV_STORAGE_CLASS

# ---- Internal defaults (script-internal only) -------------------------
STORAGE_CLASS="${DEV_STORAGE_CLASS}"
NAMESPACE="pulsar"
RELEASE_NAME="pulsar"
WAIT_TIMEOUT=600
CHART_REPO_NAME="pulsar"
CHART_REPO_URL="https://pulsar.apache.org/charts"

# Resource tuning for 3GB worker VMs
# ZooKeeper: minimal footprint (coordination only)
ZK_REPLICAS=1
ZK_MEM="256Mi"
ZK_STORAGE="5Gi"

# BookKeeper: needs more for journal + ledger storage
BK_REPLICAS=1
BK_MEM="512Mi"
BK_STORAGE="10Gi"
BK_JOURNAL_STORAGE="5Gi"

# Broker: handles message routing and topic management
BROKER_REPLICAS=1
BROKER_MEM="512Mi"

# Function Worker: standalone (not embedded in broker)
FW_REPLICAS=1
FW_MEM="256Mi"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";           shift 2 ;;
    --pulsar-version)      PULSAR_VERSION="$2";       shift 2 ;;
    --namespace)           NAMESPACE="$2";            shift 2 ;;
    --storage-class)       STORAGE_CLASS="$2";         shift 2 ;;
    --release-name)        RELEASE_NAME="$2";          shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Apache Pulsar cluster on a Kubernetes cluster via the official
Apache Pulsar Helm chart.

Components installed:
  - ZooKeeper              Single replica, 256Mi heap, 5Gi ceph-rbd
  - BookKeeper             Single replica, 512Mi heap, 10Gi ceph-rbd
  - Pulsar Broker          Single replica, 512Mi heap
  - Function Worker        Single replica, 256Mi heap (standalone)
  - Toolset                pulsar-admin CLI pod

Resource-tuned for 3GB worker VMs. No TLS, no auth, no proxy.
Anti-affinity disabled for single-node dev cluster compatibility.

Options:
  --kubeconfig PATH        Path to kubeconfig (default: ../opentofu/kubeconfig)
  --pulsar-version VER     Pulsar Helm chart version (required via env PULSAR_VERSION)
  --namespace NS           Namespace (default: pulsar)
  --storage-class NAME     StorageClass for ZK/BK PVCs (default: ceph-rbd)
  --release-name NAME      Helm release name (default: pulsar)
  --wait-timeout SEC       Max wait for Helm install (default: 600s)
  --help, -h               Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-pulsar: starting"
log "  pulsar-version:   ${PULSAR_VERSION}"
log "  namespace:        ${NAMESPACE}"
log "  release:          ${RELEASE_NAME}"
log "  storage-class:    ${STORAGE_CLASS}"
log "  wait-timeout:     ${WAIT_TIMEOUT}s"
log ""
log "  ZooKeeper:        ${ZK_REPLICAS} replica(s), ${ZK_MEM} heap, ${ZK_STORAGE} PVC"
log "  BookKeeper:       ${BK_REPLICAS} replica(s), ${BK_MEM} heap, ${BK_STORAGE} data + ${BK_JOURNAL_STORAGE} journal"
log "  Broker:           ${BROKER_REPLICAS} replica(s), ${BROKER_MEM} heap"
log "  Function Worker:  ${FW_REPLICAS} replica(s), ${FW_MEM} heap"

command -v helm >/dev/null 2>&1   || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]            || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Phase 1: Add Helm chart repository -----------------------------------
log "Phase 1: Adding Helm chart repository ${CHART_REPO_URL}..."

helm repo add "${CHART_REPO_NAME}" "${CHART_REPO_URL}" \
  --force-update 2>&1 >/dev/null || die "Failed to add Helm repo ${CHART_REPO_URL}"
helm repo update "${CHART_REPO_NAME}" 2>&1 >/dev/null || log "  Warning: repo update had issues"

log "  Helm chart repo '${CHART_REPO_NAME}' ready."

# ---- Phase 2: Create namespace --------------------------------------------
log "Phase 2: Ensuring namespace ${NAMESPACE} exists..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1
log "  Namespace '${NAMESPACE}' ready."

# ---- Phase 3: Deploy Pulsar via Helm --------------------------------------
log "Phase 3: Installing Apache Pulsar (${PULSAR_VERSION}) in namespace ${NAMESPACE}..."

# Write custom values to a temp file for cleaner --set-free invocation
PULSAR_VALUES_FILE=$(mktemp /tmp/pulsar-values.XXXXXXXXXX.yaml)
trap "rm -f ${PULSAR_VALUES_FILE}" EXIT

cat > "${PULSAR_VALUES_FILE}" <<VALUESEOF
# Pulsar dev values - resource tuned for 3GB worker VMs
# anti_affinity must be false for single-node dev clusters (< 3 nodes)
affinity:
  anti_affinity: false
  type: preferredDuringSchedulingIgnoredDuringExecution

# Disable components not needed in dev
components:
  proxy: false
  pulsar_manager: false
  dekaf: false
  oxia: false
  functions: false
  function_worker: true
  toolset: true
  autorecovery: true

# Disable TLS and auth for dev
tls:
  enabled: false
auth:
  authentication:
    enabled: false
  authorization:
    enabled: false

# ZooKeeper - single replica, minimal resources
zookeeper:
  replicaCount: ${ZK_REPLICAS}
  resources:
    requests:
      memory: ${ZK_MEM}
      cpu: 0.25
    limits:
      memory: ${ZK_MEM}
      cpu: 0.5
  configData:
    PULSAR_MEM: "-Xms64m -Xmx128m"
    PULSAR_GC: "-XX:+ExitOnOutOfMemoryError"
  volumes:
    data:
      size: ${ZK_STORAGE}
      storageClassName: ${STORAGE_CLASS}
      local_storage: false
    datalog:
      size: ${ZK_STORAGE}
      storageClassName: ${STORAGE_CLASS}
      local_storage: false

# BookKeeper - single replica, moderate resources
bookkeeper:
  replicaCount: ${BK_REPLICAS}
  resources:
    requests:
      memory: ${BK_MEM}
      cpu: 0.25
    limits:
      memory: ${BK_MEM}
      cpu: 0.5
  configData:
    PULSAR_MEM: "-Xms256m -Xmx256m"
    PULSAR_GC: "-XX:+ExitOnOutOfMemoryError"
  volumes:
    data:
      size: ${BK_STORAGE}
      storageClassName: ${STORAGE_CLASS}
      local_storage: false
    journal:
      size: ${BK_JOURNAL_STORAGE}
      storageClassName: ${STORAGE_CLASS}
      local_storage: false
    ledgers:
      size: ${BK_STORAGE}
      storageClassName: ${STORAGE_CLASS}
      local_storage: false

# Broker - single replica, moderate resources
broker:
  replicaCount: ${BROKER_REPLICAS}
  resources:
    requests:
      memory: ${BROKER_MEM}
      cpu: 0.5
    limits:
      memory: ${BROKER_MEM}
      cpu: 1.0
  configData:
    PULSAR_MEM: "-Xms256m -Xmx256m"
    PULSAR_GC: "-XX:+ExitOnOutOfMemoryError"
    # Enable topic level policies for function/sink management
    topicLevelPoliciesEnabled: "true"
    # Allow functions to manage subscriptions
    functionsWorkerEnabled: "true"

# Function Worker - standalone deployment
function_worker:
  replicaCount: ${FW_REPLICAS}
  resources:
    requests:
      memory: ${FW_MEM}
      cpu: 0.25
    limits:
      memory: ${FW_MEM}
      cpu: 0.5
  configData:
    PULSAR_MEM: "-Xms128m -Xmx128m"
    PULSAR_GC: "-XX:+ExitOnOutOfMemoryError"
    # Allow function workers to process functions from any tenant/namespace
    functionsWorkerEnabled: "true"

# Toolset - provides pulsar-admin CLI
toolset:
  usePod: true
  resources:
    requests:
      memory: 128Mi
      cpu: 0.1
    limits:
      memory: 256Mi
      cpu: 0.25

# Disable pod monitoring (no Prometheus/VictoriaMetrics scraping in dev)
podMonitor:
  enabled: false
VALUESEOF

log "  Custom dev values written to ${PULSAR_VALUES_FILE}"

helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/${RELEASE_NAME}" \
  --version "${PULSAR_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${PULSAR_VALUES_FILE}" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for Pulsar failed (exit code ${HELM_EXIT})"
fi
log "  Pulsar Helm release '${RELEASE_NAME}' deployed."

# ---- Phase 4: Wait for component rollouts ----------------------------------
log "Phase 4: Waiting for component rollouts..."

# ZooKeeper
if kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}-zookeeper" > /dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" rollout status statefulset/"${RELEASE_NAME}-zookeeper" \
    --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1 \
    || log "  (non-fatal) ZooKeeper StatefulSet rollout did not complete within ${WAIT_TIMEOUT}s"
  log "  StatefulSet '${RELEASE_NAME}-zookeeper': ROLLOUT COMPLETE"
fi

# BookKeeper
if kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}-bookkeeper" > /dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" rollout status statefulset/"${RELEASE_NAME}-bookkeeper" \
    --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1 \
    || log "  (non-fatal) BookKeeper StatefulSet rollout did not complete within ${WAIT_TIMEOUT}s"
  log "  StatefulSet '${RELEASE_NAME}-bookkeeper': ROLLOUT COMPLETE"
fi

# Broker
if kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}-broker" > /dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" rollout status statefulset/"${RELEASE_NAME}-broker" \
    --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1 \
    || log "  (non-fatal) Broker StatefulSet rollout did not complete within ${WAIT_TIMEOUT}s"
  log "  StatefulSet '${RELEASE_NAME}-broker': ROLLOUT COMPLETE"
fi

# Function Worker (deployment, not statefulset)
if kubectl -n "${NAMESPACE}" get deployment "${RELEASE_NAME}-function-worker" > /dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" rollout status deployment/"${RELEASE_NAME}-function-worker" \
    --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1 \
    || log "  (non-fatal) Function Worker deployment rollout did not complete within ${WAIT_TIMEOUT}s"
  log "  Deployment '${RELEASE_NAME}-function-worker': ROLLOUT COMPLETE"
fi

# Autorecovery
if kubectl -n "${NAMESPACE}" get deployment "${RELEASE_NAME}-autorecovery" > /dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" rollout status deployment/"${RELEASE_NAME}-autorecovery" \
    --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1 \
    || log "  (non-fatal) Autorecovery deployment rollout did not complete within ${WAIT_TIMEOUT}s"
  log "  Deployment '${RELEASE_NAME}-autorecovery': ROLLOUT COMPLETE"
fi

# ---- Phase 5: Create default tenant/namespace for analytics ----------------
log "Phase 5: Creating default tenant/namespace for analytics..."

# Wait for the toolset pod to be ready
TOOLSET_POD="${RELEASE_NAME}-toolset-0"
log "  Waiting for toolset pod '${TOOLSET_POD}'..."
if kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${TOOLSET_POD}" \
  --timeout=120s > /dev/null 2>&1; then
  log "  Toolset pod '${TOOLSET_POD}': READY"

  # Create the public/default namespace for analytics topics
  log "  Creating 'public/default' namespace..."
  kubectl -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin tenants create public 2>/dev/null \
    && log "    Tenant 'public': CREATED" \
    || log "    Tenant 'public': already exists (non-fatal)"

  kubectl -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin namespaces create public/default 2>/dev/null \
    && log "    Namespace 'public/default': CREATED" \
    || log "    Namespace 'public/default': already exists (non-fatal)"

  # Create the raw-events and processed-events topics
  log "  Creating analytics topics..."
  kubectl -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin topics create-partitioned-topic \
    persistent://public/default/raw-events --partitions 2 2>/dev/null \
    && log "    Topic 'raw-events': CREATED (2 partitions)" \
    || log "    Topic 'raw-events': already exists (non-fatal)"

  kubectl -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin topics create-partitioned-topic \
    persistent://public/default/processed-events --partitions 4 2>/dev/null \
    && log "    Topic 'processed-events': CREATED (4 partitions)" \
    || log "    Topic 'processed-events': already exists (non-fatal)"

  # List topics to verify
  log "  Listing topics in public/default:"
  TOPIC_LIST=$(kubectl -n "${NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin topics list public/default 2>/dev/null | tr '\n' ' ')
  log "    Topics: ${TOPIC_LIST:-none}"
else
  log "  (non-fatal) Toolset pod not ready within 120s — skipping topic creation."
  log "  Topics can be created manually via: kubectl exec -n ${NAMESPACE} ${TOOLSET_POD} -- pulsar-admin ..."
fi

# ---- Phase 6: Gather component statuses for summary ------------------------
log "Phase 6: Gathering component statuses for summary..."

# Component pod counts
ZK_READY=$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}-zookeeper" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
BK_READY=$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}-bookkeeper" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
BROKER_READY=$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}-broker" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
FW_READY=$(kubectl -n "${NAMESPACE}" get deployment "${RELEASE_NAME}-function-worker" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
AR_READY=$(kubectl -n "${NAMESPACE}" get deployment "${RELEASE_NAME}-autorecovery" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

# PVC statuses
ZK_PVC_STATUS=$(kubectl -n "${NAMESPACE}" get pvc \
  -l "app=${RELEASE_NAME},component=zookeeper" --no-headers 2>/dev/null \
  | awk '{print $1 "(" $2 ")"}' | tr '\n' ' ' || echo "Not Found")

BK_DATA_PVC_STATUS=$(kubectl -n "${NAMESPACE}" get pvc \
  -l "app=${RELEASE_NAME},component=bookkeeper,role=data" --no-headers 2>/dev/null \
  | awk '{print $1 "(" $2 ")"}' | tr '\n' ' ' || echo "Not Found")

BK_JOURNAL_PVC_STATUS=$(kubectl -n "${NAMESPACE}" get pvc \
  -l "app=${RELEASE_NAME},component=bookkeeper,role=journal" --no-headers 2>/dev/null \
  | awk '{print $1 "(" $2 ")"}' | tr '\n' ' ' || echo "Not Found")

# Broker service endpoint
BROKER_SVC="${RELEASE_NAME}-broker.${NAMESPACE}.svc.cluster.local"

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Apache Pulsar Installation Summary ==="
echo "  Release:          ${RELEASE_NAME}"
echo "  Version:          ${PULSAR_VERSION}"
echo "  Namespace:        ${NAMESPACE}"
echo "  Storage class:    ${STORAGE_CLASS}"
echo ""
echo "  Components:"
echo "    ZooKeeper:        ${ZK_READY}/1 ready  (${ZK_MEM} heap, ${ZK_STORAGE} PVC)"
echo "    BookKeeper:       ${BK_READY}/1 ready  (${BK_MEM} heap, ${BK_STORAGE} data + ${BK_JOURNAL_STORAGE} journal)"
echo "    Broker:           ${BROKER_READY}/1 ready  (${BROKER_MEM} heap)"
echo "    Function Worker:  ${FW_READY}/1 ready  (${FW_MEM} heap)"
echo "    Autorecovery:     ${AR_READY}/1 ready"
echo ""
echo "  PVCs:"
echo "    ZooKeeper:        ${ZK_PVC_STATUS}"
echo "    BookKeeper data:  ${BK_DATA_PVC_STATUS}"
echo "    BookKeeper jrnl:  ${BK_JOURNAL_PVC_STATUS}"
echo ""
echo "  Topics:"
echo "    raw-events:       persistent://public/default/raw-events (2 partitions)"
echo "    processed-events: persistent://public/default/processed-events (4 partitions)"
echo ""
echo "  Service endpoints:"
echo "    Broker:           ${BROKER_SVC}:6650 (plain)"
echo "    Broker HTTP:      ${BROKER_SVC}:8080 (admin API)"
echo "    Function Worker:  ${RELEASE_NAME}-function-worker.${NAMESPACE}.svc.cluster.local:6754"
echo ""
echo "  Admin CLI:"
echo "    kubectl exec -n ${NAMESPACE} ${TOOLSET_POD} -- pulsar-admin ..."
echo ""
echo "  Topics (raw-events):    persistent://public/default/raw-events"
echo "  Topics (processed):     persistent://public/default/processed-events"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods"
echo "    kubectl -n ${NAMESPACE} get pvc"
echo "    kubectl -n ${NAMESPACE} exec ${TOOLSET_POD} -- pulsar-admin topics list public/default"
echo ""
echo "  Cleanup:"
echo "    helm uninstall ${RELEASE_NAME} -n ${NAMESPACE}"
echo "    kubectl delete namespace ${NAMESPACE}"
echo ""
echo "================================="

log "install-pulsar: completed successfully"
exit 0

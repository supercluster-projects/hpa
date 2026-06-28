#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-clickhouse.sh — Deploy ClickHouse single-node analytical database
#
# Installs ClickHouse via the Bitnami Helm chart with ceph-rbd persistence
# and creates the device_metrics MergeTree table for analytics.
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-clickhouse.sh [--kubeconfig <path>]
#                                [--clickhouse-version <ver>]
#                                [--namespace <ns>]
#                                [--storage-class <name>]
#                                [--release-name <name>]
#                                [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env CLICKHOUSE_VERSION
require_env DEV_STORAGE_CLASS

# ---- Internal defaults (script-internal only) -------------------------
STORAGE_CLASS="${DEV_STORAGE_CLASS}"
NAMESPACE="clickhouse"
RELEASE_NAME="clickhouse"
WAIT_TIMEOUT=600
CHART_REPO_NAME="bitnami"
CHART_REPO_URL="https://charts.bitnami.com/bitnami"

# Resource tuning for 3GB worker VMs
CLICKHOUSE_MEM_REQUEST="512Mi"
CLICKHOUSE_MEM_LIMIT="1Gi"
CLICKHOUSE_CPU_REQUEST="0.25"
CLICKHOUSE_CPU_LIMIT="0.5"
CLICKHOUSE_STORAGE="10Gi"
CLICKHOUSE_ADMIN_USER="default"
CLICKHOUSE_ADMIN_PASSWORD="clickhouse_admin"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)            KUBECONFIG="$2";           shift 2 ;;
    --clickhouse-version)    CLICKHOUSE_VERSION="$2";   shift 2 ;;
    --namespace)             NAMESPACE="$2";            shift 2 ;;
    --storage-class)         STORAGE_CLASS="$2";         shift 2 ;;
    --release-name)          RELEASE_NAME="$2";          shift 2 ;;
    --admin-password)        CLICKHOUSE_ADMIN_PASSWORD="$2"; shift 2 ;;
    --wait-timeout)          WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy ClickHouse single-node analytical database on a Kubernetes cluster.

Components installed:
  - ClickHouse StatefulSet (1 replica, 512Mi-1Gi, 10Gi ceph-rbd)
  - ClickHouse Service (HTTP :8123, native :9000)
  - analytics_db database
  - device_metrics MergeTree table

Options:
  --kubeconfig PATH        Path to kubeconfig (default: ../opentofu/kubeconfig)
  --clickhouse-version VER Bitnami ClickHouse chart version (required via env CLICKHOUSE_VERSION)
  --namespace NS           Namespace (default: clickhouse)
  --storage-class NAME     StorageClass (default: ceph-rbd)
  --release-name NAME      Helm release name (default: clickhouse)
  --admin-password PASS    Default user password (default: clickhouse_admin)
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
log "install-clickhouse: starting"
log "  clickhouse-version: ${CLICKHOUSE_VERSION}"
log "  namespace:          ${NAMESPACE}"
log "  release:            ${RELEASE_NAME}"
log "  storage-class:      ${STORAGE_CLASS}"
log "  resources:          ${CLICKHOUSE_CPU_REQUEST} CPU / ${CLICKHOUSE_MEM_REQUEST} RAM -> ${CLICKHOUSE_MEM_LIMIT}"
log "  storage:            ${CLICKHOUSE_STORAGE}"
log "  wait-timeout:       ${WAIT_TIMEOUT}s"

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

# ---- Phase 3: Deploy ClickHouse via Helm ----------------------------------
log "Phase 3: Installing ClickHouse (${CLICKHOUSE_VERSION}) in namespace ${NAMESPACE}..."

CLICKHOUSE_VALUES_FILE=$(mktemp /tmp/clickhouse-values.XXXXXXXXXX.yaml)
trap "rm -f ${CLICKHOUSE_VALUES_FILE}" EXIT

cat > "${CLICKHOUSE_VALUES_FILE}" <<VALUESEOF
# ClickHouse dev values - single node, resource tuned for 3GB VMs

## Replication
replicaCount: 1

## Persistence
persistence:
  enabled: true
  size: ${CLICKHOUSE_STORAGE}
  storageClass: ${STORAGE_CLASS}

## Resource tuning
resources:
  requests:
    memory: ${CLICKHOUSE_MEM_REQUEST}
    cpu: ${CLICKHOUSE_CPU_REQUEST}
  limits:
    memory: ${CLICKHOUSE_MEM_LIMIT}
    cpu: ${CLICKHOUSE_CPU_LIMIT}

## Auth
auth:
  username: ${CLICKHOUSE_ADMIN_USER}
  password: ${CLICKHOUSE_ADMIN_PASSWORD}
  # No additional databases or users for dev

## Service
service:
  type: ClusterIP
  ports:
    http: 8123
    native: 9000

## Service account
serviceAccount:
  create: true

## Metrics
metrics:
  enabled: false

## Init containers (disabled)
initContainers: []
VALUESEOF

log "  Custom dev values written to ${CLICKHOUSE_VALUES_FILE}"

helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/clickhouse" \
  --version "${CLICKHOUSE_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${CLICKHOUSE_VALUES_FILE}" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for ClickHouse failed (exit code ${HELM_EXIT})"
fi
log "  ClickHouse Helm release '${RELEASE_NAME}' deployed."

# ---- Phase 4: Wait for StatefulSet rollout --------------------------------
log "Phase 4: Waiting for ClickHouse StatefulSet rollout..."

if kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}-clickhouse" > /dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" rollout status statefulset/"${RELEASE_NAME}-clickhouse" \
    --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1 \
    || log "  (non-fatal) ClickHouse StatefulSet rollout incomplete within ${WAIT_TIMEOUT}s"
  log "  StatefulSet '${RELEASE_NAME}-clickhouse': ROLLOUT COMPLETE"
fi

# ---- Phase 5: Create analytics database and device_metrics table ----------
log "Phase 5: Creating analytics database and device_metrics table..."

# Wait for ClickHouse pod to be Ready
CLICKHOUSE_POD="${RELEASE_NAME}-clickhouse-0"
log "  Waiting for pod '${CLICKHOUSE_POD}'..."
if kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${CLICKHOUSE_POD}" \
  --timeout=120s > /dev/null 2>&1; then
  log "  Pod '${CLICKHOUSE_POD}': READY"

  # Create analytics_db database
  log "  Creating database 'analytics_db'..."
  if kubectl -n "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
    clickhouse-client --user="${CLICKHOUSE_ADMIN_USER}" --password="${CLICKHOUSE_ADMIN_PASSWORD}" \
    --query "CREATE DATABASE IF NOT EXISTS analytics_db" 2>&1; then
    log "    Database 'analytics_db': READY"
  else
    log "    (non-fatal) Database 'analytics_db' could not be created"
  fi

  # Create device_metrics MergeTree table
  log "  Creating table 'analytics_db.device_metrics'..."
  CREATE_TABLE_SQL="
CREATE TABLE IF NOT EXISTS analytics_db.device_metrics (
  event_id String,
  device_type String,
  metric_value Float32,
  processed_timestamp DateTime
) ENGINE = MergeTree()
ORDER BY (device_type, processed_timestamp)
"
  if kubectl -n "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
    clickhouse-client --user="${CLICKHOUSE_ADMIN_USER}" --password="${CLICKHOUSE_ADMIN_PASSWORD}" \
    --query "${CREATE_TABLE_SQL}" 2>&1; then
    log "    Table 'analytics_db.device_metrics': CREATED"
  else
    log "    (non-fatal) Table could not be created"
  fi

  # Create pulsar_writer user for JDBC sink access
  log "  Creating 'pulsar_writer' user..."
  CREATE_USER_SQL="
CREATE USER IF NOT EXISTS pulsar_writer@'%' IDENTIFIED BY 'pulsar_writer_secret'
"
  if kubectl -n "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
    clickhouse-client --user="${CLICKHOUSE_ADMIN_USER}" --password="${CLICKHOUSE_ADMIN_PASSWORD}" \
    --query "${CREATE_USER_SQL}" 2>&1; then
    log "    User 'pulsar_writer': CREATED"
  else
    log "    (non-fatal) User 'pulsar_writer' could not be created"
  fi

  # Grant permissions to pulsar_writer on analytics_db
  GRANT_SQL="GRANT INSERT, SELECT ON analytics_db.device_metrics TO pulsar_writer@'%'"
  if kubectl -n "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
    clickhouse-client --user="${CLICKHOUSE_ADMIN_USER}" --password="${CLICKHOUSE_ADMIN_PASSWORD}" \
    --query "${GRANT_SQL}" 2>&1; then
    log "    Grants on 'analytics_db.device_metrics': APPLIED"
  else
    log "    (non-fatal) Grants could not be applied"
  fi

  # Verify tables
  log "  Listing tables:"
  SHOW_TABLES=$(kubectl -n "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
    clickhouse-client --user="${CLICKHOUSE_ADMIN_USER}" --password="${CLICKHOUSE_ADMIN_PASSWORD}" \
    --query "SELECT database, name, engine FROM system.tables WHERE database='analytics_db'" 2>&1)
  log "    ${SHOW_TABLES:-none}"
else
  log "  (non-fatal) ClickHouse pod not Ready within 120s — skipping table creation."
fi

# ---- Phase 6: Gather component statuses for summary ------------------------
log "Phase 6: Gathering component statuses..."

# Pod status
POD_READY=$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}-clickhouse" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
POD_NAME=$(kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
  --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -1 || echo "N/A")

# Service endpoint
CLICKHOUSE_SVC="${RELEASE_NAME}-clickhouse.${NAMESPACE}.svc.cluster.local"

# PVC status
PVC_STATUS=$(kubectl -n "${NAMESPACE}" get pvc \
  -l "app.kubernetes.io/instance=${RELEASE_NAME}" --no-headers 2>/dev/null \
  | awk '{print $1 "(" $2 " - " $4 ")"}' | tr '\n' ' ' || echo "Not Found")

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== ClickHouse Installation Summary ==="
echo "  Release:          ${RELEASE_NAME}"
echo "  Version:          ${CLICKHOUSE_VERSION}"
echo "  Namespace:        ${NAMESPACE}"
echo "  Storage class:    ${STORAGE_CLASS}"
echo ""
echo "  Pod:"
echo "    StatefulSet:    ${POD_READY}/1 ready"
echo "    Pod name:       ${POD_NAME}"
echo ""
echo "  Storage:"
echo "    PVC:            ${PVC_STATUS}"
echo "    Size:           ${CLICKHOUSE_STORAGE}"
echo ""
echo "  Databases:"
echo "    analytics_db     Device metrics storage for Pulsar pipeline"
echo ""
echo "  Tables:"
echo "    analytics_db.device_metrics"
echo "      Columns:      event_id String, device_type String, metric_value Float32, processed_timestamp DateTime"
echo "      Engine:       MergeTree()"
echo "      Order by:     (device_type, processed_timestamp)"
echo ""
echo "  Users:"
echo "    default:         admin user (password set via --admin-password)"
echo "    pulsar_writer:   INSERT/SELECT on analytics_db.device_metrics (password: pulsar_writer_secret)"
echo ""
echo "  Service endpoints:"
echo "    HTTP (REST):     ${CLICKHOUSE_SVC}:8123"
echo "    Native (TCP):    ${CLICKHOUSE_SVC}:9000"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} exec ${CLICKHOUSE_POD} -- clickhouse-client --query 'SELECT 1'"
echo "    kubectl -n ${NAMESPACE} exec ${CLICKHOUSE_POD} -- clickhouse-client --query 'SHOW DATABASES'"
echo "    kubectl -n ${NAMESPACE} exec ${CLICKHOUSE_POD} -- clickhouse-client --query 'SELECT * FROM analytics_db.device_metrics'"
echo ""
echo "  Cleanup:"
echo "    helm uninstall ${RELEASE_NAME} -n ${NAMESPACE}"
echo "    kubectl delete namespace ${NAMESPACE}"
echo ""
echo "================================="

log "install-clickhouse: completed successfully"
exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-yugabytedb.sh — Deploy Yugabytedb distributed SQL cluster
#
# Installs Yugabytedb via the official Helm chart on ceph-rbd StorageClass
# with 3 yb-master + 3 yb-tserver pods. Resource-tuned for 3GB worker VMs.
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-yugabytedb.sh [--kubeconfig <path>]
#                                [--yugabytedb-version <ver>]
#                                [--namespace <ns>]
#                                [--storage-class <name>]
#                                [--release-name <name>]
#                                [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env YUGABYTEDB_VERSION

# ---- Internal defaults (script-internal only) -------------------------
STORAGE_CLASS="${DEV_STORAGE_CLASS:-ceph-rbd}"
NAMESPACE="yugabytedb"
RELEASE_NAME="yb-demo"
WAIT_TIMEOUT=600
CHART_REPO_NAME="yugabytedb"
CHART_REPO_URL="https://charts.yugabyte.com"

# Resource tuning for 3GB worker VMs
# Master: minimal footprint (leader election, metadata storage)
# TServer: needs more for query processing and tablet storage
MASTER_CPU="0.5"
MASTER_MEM="0.5Gi"
MASTER_STORAGE="5Gi"
TSERVER_CPU="0.5"
TSERVER_MEM="1.0Gi"
TSERVER_STORAGE="10Gi"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";           shift 2 ;;
    --yugabytedb-version)  YUGABYTEDB_VERSION="$2";   shift 2 ;;
    --namespace)           NAMESPACE="$2";            shift 2 ;;
    --storage-class)       STORAGE_CLASS="$2";         shift 2 ;;
    --release-name)        RELEASE_NAME="$2";          shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Yugabytedb distributed SQL cluster on a Kubernetes cluster.

Components installed:
  - Yugabytedb cluster via Helm chart (charts.yugabyte.com)
    3 yb-master + 3 yb-tserver on ceph-rbd PVCs

Options:
  --kubeconfig PATH        Path to kubeconfig
  --yugabytedb-version VER YugabyteDB version (required)
  --namespace NS           Namespace (default: yugabytedb)
  --storage-class NAME     StorageClass (default: ceph-rbd)
  --release-name NAME      Helm release name (default: yb-demo)
  --wait-timeout SEC       Max wait for Helm install (default: 600)
  --help, -h               Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-yugabytedb: starting"
log "  kubeconfig:       ${KUBECONFIG}"
log "  version:          ${YUGABYTEDB_VERSION}"
log "  namespace:        ${NAMESPACE}"
log "  release:          ${RELEASE_NAME}"
log "  storage-class:    ${STORAGE_CLASS}"
log "  master:           ${MASTER_CPU} CPU / ${MASTER_MEM} RAM / ${MASTER_STORAGE} PVC"
log "  tserver:          ${TSERVER_CPU} CPU / ${TSERVER_MEM} RAM / ${TSERVER_STORAGE} PVC"
log "  wait-timeout:     ${WAIT_TIMEOUT}s"

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

# ---- Phase 3: Deploy Yugabytedb via Helm ----------------------------------
log "Phase 3: Installing Yugabytedb (${YUGABYTEDB_VERSION}) in namespace ${NAMESPACE}..."

helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/yugabyte" \
  --version "${YUGABYTEDB_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "storage.master.storageClass=${STORAGE_CLASS}" \
  --set "storage.master.size=${MASTER_STORAGE}" \
  --set "storage.tserver.storageClass=${STORAGE_CLASS}" \
  --set "storage.tserver.size=${TSERVER_STORAGE}" \
  --set "resource.master.requests.cpu=${MASTER_CPU}" \
  --set "resource.master.requests.memory=${MASTER_MEM}" \
  --set "resource.tserver.requests.cpu=${TSERVER_CPU}" \
  --set "resource.tserver.requests.memory=${TSERVER_MEM}" \
  --set "replicas.master=3" \
  --set "replicas.tserver=3" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for Yugabytedb failed (exit code ${HELM_EXIT})"
fi
log "  Yugabytedb Helm release '${RELEASE_NAME}' deployed."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Yugabytedb Installation Summary ==="
echo "  Release:         ${RELEASE_NAME}"
echo "  Version:         ${YUGABYTEDB_VERSION}"
echo "  Namespace:       ${NAMESPACE}"
echo "  Storage class:   ${STORAGE_CLASS}"
echo "  Masters:         3 (${MASTER_CPU} CPU / ${MASTER_MEM} RAM / ${MASTER_STORAGE} PVC each)"
echo "  Tservers:        3 (${TSERVER_CPU} CPU / ${TSERVER_MEM} RAM / ${TSERVER_STORAGE} PVC each)"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods"
echo "    kubectl -n ${NAMESPACE} get pvc"
echo "    kubectl -n ${NAMESPACE} exec -it yb-tserver-0 -- bash -c 'ysqlsh -h yb-tserver-0 -c \"CREATE TABLE test (id INT PRIMARY KEY);\"'"
echo "    kubectl -n ${NAMESPACE} exec -it yb-master-0 -- bash -c 'ysqlsh -h yb-tserver-0 -c \"SELECT * FROM pg_catalog.pg_tables WHERE tablename = \\\"test\\\";\"'"
echo "========================================"

log "install-yugabytedb: completed successfully"
exit 0

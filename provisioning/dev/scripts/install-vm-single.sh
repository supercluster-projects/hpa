#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-vm-single.sh — Deploy VictoriaMetrics VMSingle (single-node TSDB)
#
# Installs VictoriaMetrics Single as the metrics storage backend. Provides
# a Prometheus-compatible endpoint that vmagent and Grafana can consume.
# Resource-tuned for 3GB worker VMs.
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-vm-single.sh [--kubeconfig <path>]
#                               [--vm-version <ver>]
#                               [--namespace <ns>]
#                               [--retention-period <duration>]
#                               [--storage-size <size>]
#                               [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env VICTORIAMETRICS_VERSION

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="observability"
RELEASE_NAME="vmsingle"
WAIT_TIMEOUT=600
CHART_REPO_NAME="vm"
CHART_REPO_URL="https://victoriametrics.github.io/helm-charts"
RETENTION_PERIOD="7d"
STORAGE_SIZE="5Gi"

# Resource tuning for 3GB worker VMs
VM_CPU_REQUEST="0.2"
VM_MEM_REQUEST="200Mi"
VM_CPU_LIMIT="0.5"
VM_MEM_LIMIT="500Mi"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";           shift 2 ;;
    --vm-version)          VICTORIAMETRICS_VERSION="$2"; shift 2 ;;
    --namespace)           NAMESPACE="$2";            shift 2 ;;
    --retention-period)    RETENTION_PERIOD="$2";      shift 2 ;;
    --storage-size)        STORAGE_SIZE="$2";          shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy VictoriaMetrics Single (VMSingle) as metrics storage.

Options:
  --kubeconfig PATH        Path to kubeconfig
  --vm-version VER         VictoriaMetrics version (required)
  --namespace NS           Namespace (default: observability)
  --retention-period DUR   Retention period (default: 7d)
  --storage-size SIZE      PVC size for metrics (default: 5Gi)
  --wait-timeout SEC       Max wait (default: 600)
  --help, -h               Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-vm-single: starting"
log "  kubeconfig:       ${KUBECONFIG}"
log "  version:          ${VICTORIAMETRICS_VERSION}"
log "  namespace:        ${NAMESPACE}"
log "  release:          ${RELEASE_NAME}"
log "  retention:        ${RETENTION_PERIOD}"
log "  storage:          ${STORAGE_SIZE}"
log "  resources:        req ${VM_CPU_REQUEST}/${VM_MEM_REQUEST}, lim ${VM_CPU_LIMIT}/${VM_MEM_LIMIT}"
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

# ---- Phase 3: Deploy VMSingle via Helm ------------------------------------
log "Phase 3: Installing VictoriaMetrics Single (${VICTORIAMETRICS_VERSION}) in namespace ${NAMESPACE}..."

helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/victoria-metrics-single" \
  --version "${VICTORIAMETRICS_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "server.retentionPeriod=${RETENTION_PERIOD}" \
  --set "persistence.enabled=true" \
  --set "persistence.size=${STORAGE_SIZE}" \
  --set "resources.requests.cpu=${VM_CPU_REQUEST}" \
  --set "resources.requests.memory=${VM_MEM_REQUEST}" \
  --set "resources.limits.cpu=${VM_CPU_LIMIT}" \
  --set "resources.limits.memory=${VM_MEM_LIMIT}" \
  --set "service.type=ClusterIP" \
  --set "service.port=8428" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for VMSingle failed (exit code ${HELM_EXIT})"
fi
log "  VMSingle Helm release '${RELEASE_NAME}' deployed."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== VictoriaMetrics Single Installation Summary ==="
echo "  Release:         ${RELEASE_NAME}"
echo "  Version:         ${VICTORIAMETRICS_VERSION}"
echo "  Namespace:       ${NAMESPACE}"
echo "  Service:         ClusterIP :8428"
echo "  Retention:       ${RETENTION_PERIOD}"
echo "  Storage:         ${STORAGE_SIZE}"
echo "  Resources:       req ${VM_CPU_REQUEST}/${VM_MEM_REQUEST}, lim ${VM_CPU_LIMIT}/${VM_MEM_LIMIT}"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods"
echo "    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-victoria-metrics-single 8428:8428 &"
echo "    curl http://localhost:8428/metrics | head -20"
echo "    curl http://localhost:8428/api/v1/targets | head -5"
echo "=============================================="

log "install-vm-single: completed successfully"
exit 0

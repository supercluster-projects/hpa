#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-kube-state-metrics.sh — Deploy kube-state-metrics
#
# Installs kube-state-metrics from the prometheus-community Helm chart.
# Generates cluster-level resource metrics (pod counts, deployments, nodes,
# etc.) that vmagent scrapes and sends to VMSingle.
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-kube-state-metrics.sh [--kubeconfig <path>]
#                                        [--ksm-version <ver>]
#                                        [--namespace <ns>]
#                                        [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
require_env KUBE_STATE_METRICS_VERSION

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="observability"
RELEASE_NAME="kube-state-metrics"
WAIT_TIMEOUT=300
CHART_REPO_NAME="prometheus-community"
CHART_REPO_URL="https://prometheus-community.github.io/helm-charts"

# Resource tuning for 3GB worker VMs
KSM_CPU_REQUEST="0.05"
KSM_MEM_REQUEST="30Mi"
KSM_CPU_LIMIT="0.2"
KSM_MEM_LIMIT="100Mi"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";           shift 2 ;;
    --ksm-version)         KUBE_STATE_METRICS_VERSION="$2"; shift 2 ;;
    --namespace)           NAMESPACE="$2";            shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy kube-state-metrics for cluster-level resource metrics.

Options:
  --kubeconfig PATH        Path to kubeconfig
  --ksm-version VER        kube-state-metrics chart version (required)
  --namespace NS           Namespace (default: observability)
  --wait-timeout SEC       Max wait (default: 300)
  --help, -h               Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-kube-state-metrics: starting"
log "  kubeconfig:       ${KUBECONFIG}"
log "  version:          ${KUBE_STATE_METRICS_VERSION}"
log "  namespace:        ${NAMESPACE}"
log "  release:          ${RELEASE_NAME}"
log "  resources:        req ${KSM_CPU_REQUEST}/${KSM_MEM_REQUEST}, lim ${KSM_CPU_LIMIT}/${KSM_MEM_LIMIT}"
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

# ---- Phase 2: Create namespace (idempotent) -------------------------------
log "Phase 2: Ensuring namespace ${NAMESPACE} exists..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1

# ---- Phase 3: Deploy kube-state-metrics via Helm --------------------------
log "Phase 3: Installing kube-state-metrics (${KUBE_STATE_METRICS_VERSION})..."

helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/kube-state-metrics" \
  --version "${KUBE_STATE_METRICS_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "resources.requests.cpu=${KSM_CPU_REQUEST}" \
  --set "resources.requests.memory=${KSM_MEM_REQUEST}" \
  --set "resources.limits.cpu=${KSM_CPU_LIMIT}" \
  --set "resources.limits.memory=${KSM_MEM_LIMIT}" \
  --set "service.type=ClusterIP" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for kube-state-metrics failed (exit code ${HELM_EXIT})"
fi
log "  kube-state-metrics Helm release '${RELEASE_NAME}' deployed."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== kube-state-metrics Installation Summary ==="
echo "  Release:         ${RELEASE_NAME}"
echo "  Version:         ${KUBE_STATE_METRICS_VERSION}"
echo "  Namespace:       ${NAMESPACE}"
echo "  Resources:       req ${KSM_CPU_REQUEST}/${KSM_MEM_REQUEST}, lim ${KSM_CPU_LIMIT}/${KSM_MEM_LIMIT}"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=kube-state-metrics"
echo "    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME} 8080:8080 &"
echo "    curl http://localhost:8080/metrics | head -20"
echo "=============================================="

log "install-kube-state-metrics: completed successfully"
exit 0

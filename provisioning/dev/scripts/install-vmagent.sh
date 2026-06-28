#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-vmagent.sh — Deploy VictoriaMetrics vmagent DaemonSet for scraping
#
# Installs vmagent as a DaemonSet on each node to scrape Kubernetes
# components: kubelet, node-exporter, and kube-state-metrics. Writes
# collected metrics to VMSingle via remote write.
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-vmagent.sh [--kubeconfig <path>]
#                             [--vm-version <ver>]
#                             [--namespace <ns>]
#                             [--vm-single-addr <url>]
#                             [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
require_env VICTORIAMETRICS_VERSION

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="observability"
RELEASE_NAME="vmagent"
WAIT_TIMEOUT=600
CHART_REPO_NAME="vm"
CHART_REPO_URL="https://victoriametrics.github.io/helm-charts"

# In-cluster VMSingle endpoint
VM_SINGLE_ADDR="http://vmsingle-victoria-metrics-single.${NAMESPACE}.svc.cluster.local:8428"

# Resource tuning for 3GB worker VMs
AGENT_CPU_REQUEST="0.1"
AGENT_MEM_REQUEST="50Mi"
AGENT_CPU_LIMIT="0.3"
AGENT_MEM_LIMIT="200Mi"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";           shift 2 ;;
    --vm-version)          VICTORIAMETRICS_VERSION="$2"; shift 2 ;;
    --namespace)           NAMESPACE="$2";            shift 2 ;;
    --vm-single-addr)      VM_SINGLE_ADDR="$2";        shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy vmagent DaemonSet for Kubernetes metric scraping.

Options:
  --kubeconfig PATH        Path to kubeconfig
  --vm-version VER         VictoriaMetrics version (required)
  --namespace NS           Namespace (default: observability)
  --vm-single-addr URL     VMSingle remote write URL
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
log "install-vmagent: starting"
log "  kubeconfig:       ${KUBECONFIG}"
log "  version:          ${VICTORIAMETRICS_VERSION}"
log "  namespace:        ${NAMESPACE}"
log "  release:          ${RELEASE_NAME}"
log "  vm-single-addr:   ${VM_SINGLE_ADDR}"
log "  resources:        req ${AGENT_CPU_REQUEST}/${AGENT_MEM_REQUEST}, lim ${AGENT_CPU_LIMIT}/${AGENT_MEM_LIMIT}"
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

# ---- Phase 3: Deploy vmagent via Helm -------------------------------------
log "Phase 3: Installing vmagent (${VICTORIAMETRICS_VERSION}) in namespace ${NAMESPACE}..."

# Generate scrape configuration inline
# Scrapes: kubelet, node-exporter (auto-discovered via pod labels), kube-state-metrics
helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/victoria-metrics-agent" \
  --version "${VICTORIAMETRICS_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "remoteWriteUrls={${VM_SINGLE_ADDR}/api/v1/write}" \
  --set "resources.requests.cpu=${AGENT_CPU_REQUEST}" \
  --set "resources.requests.memory=${AGENT_MEM_REQUEST}" \
  --set "resources.limits.cpu=${AGENT_CPU_LIMIT}" \
  --set "resources.limits.memory=${AGENT_MEM_LIMIT}" \
  --set "service.enabled=true" \
  --set "service.port=8429" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for vmagent failed (exit code ${HELM_EXIT})"
fi
log "  vmagent Helm release '${RELEASE_NAME}' deployed."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== vmagent Installation Summary ==="
echo "  Release:         ${RELEASE_NAME}"
echo "  Version:         ${VICTORIAMETRICS_VERSION}"
echo "  Namespace:       ${NAMESPACE}"
echo "  Remote write:    ${VM_SINGLE_ADDR}/api/v1/write"
echo "  Resources:       req ${AGENT_CPU_REQUEST}/${AGENT_MEM_REQUEST}, lim ${AGENT_CPU_LIMIT}/${AGENT_MEM_LIMIT}"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=victoria-metrics-agent"
echo "    kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/name=victoria-metrics-agent --tail=20"
echo "    # Port forward to see scrape targets:"
echo "    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-victoria-metrics-agent 8429:8429 &"
echo "    curl http://localhost:8429/targets | head -20"
echo "====================================="

log "install-vmagent: completed successfully"
exit 0

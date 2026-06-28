#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-alertmanager.sh — Deploy AlertManager with basic K8s alerting rules
#
# Installs AlertManager from the prometheus-community Helm chart with basic
# alerting rules for Kubernetes: pod restarts, node memory pressure, OOM kills.
# Rules fire alerts visible in Grafana and the AlertManager web UI.
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-alertmanager.sh [--kubeconfig <path>]
#                                 [--alertmanager-version <ver>]
#                                 [--namespace <ns>]
#                                 [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
require_env ALERTMANAGER_VERSION

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="observability"
RELEASE_NAME="alertmanager"
WAIT_TIMEOUT=600
CHART_REPO_NAME="prometheus-community"
CHART_REPO_URL="https://prometheus-community.github.io/helm-charts"

# Resource tuning for 3GB worker VMs
AM_CPU_REQUEST="0.05"
AM_MEM_REQUEST="30Mi"
AM_CPU_LIMIT="0.2"
AM_MEM_LIMIT="150Mi"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)             KUBECONFIG="$2";              shift 2 ;;
    --alertmanager-version)   ALERTMANAGER_VERSION="$2";    shift 2 ;;
    --namespace)              NAMESPACE="$2";               shift 2 ;;
    --wait-timeout)           WAIT_TIMEOUT="$2";              shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy AlertManager with basic K8s alerting rules.

Options:
  --kubeconfig PATH         Path to kubeconfig
  --alertmanager-version    AlertManager chart version (required)
  --namespace NS            Namespace (default: observability)
  --wait-timeout SEC        Max wait (default: 600)
  --help, -h                Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-alertmanager: starting"
log "  kubeconfig:       ${KUBECONFIG}"
log "  version:          ${ALERTMANAGER_VERSION}"
log "  namespace:        ${NAMESPACE}"
log "  release:          ${RELEASE_NAME}"
log "  resources:        req ${AM_CPU_REQUEST}/${AM_MEM_REQUEST}, lim ${AM_CPU_LIMIT}/${AM_MEM_LIMIT}"
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

# ---- Phase 3: Create alerting rules ConfigMap -----------------------------
log "Phase 3: Creating alerting rules..."

cat <<'RULES' | kubectl apply -f - > /dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-rules
  namespace: observability
  labels:
    app.kubernetes.io/name: alertmanager
data:
  k8s-alerts.yml: |
    groups:
      - name: k8s-platform
        rules:
          - alert: Watchdog
            expr: vector(1)
            labels:
              severity: none
            annotations:
              summary: "AlertManager watchdog — confirming alert pipeline is working"

          - alert: PodRestarting
            expr: rate(kube_pod_container_status_restarts_total[15m]) > 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Pod {{ $labels.pod }} is restarting frequently ({{ $value }}/15m)"
              description: "Container {{ $labels.container }} in pod {{ $labels.pod }} in namespace {{ $labels.namespace }}"

          - alert: NodeMemoryPressure
            expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "Node {{ $labels.node }} has less than 10% memory available"

          - alert: PodOOMKilled
            expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
            labels:
              severity: critical
            annotations:
              summary: "Pod {{ $labels.pod }} was OOMKilled"
              description: "Container {{ $labels.container }} in namespace {{ $labels.namespace }} was killed due to out of memory"
RULES

log "  Alerting rules ConfigMap applied."

# ---- Phase 4: Deploy AlertManager via Helm --------------------------------
log "Phase 4: Installing AlertManager (${ALERTMANAGER_VERSION})..."

helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/alertmanager" \
  --version "${ALERTMANAGER_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "resources.requests.cpu=${AM_CPU_REQUEST}" \
  --set "resources.requests.memory=${AM_MEM_REQUEST}" \
  --set "resources.limits.cpu=${AM_CPU_LIMIT}" \
  --set "resources.limits.memory=${AM_MEM_LIMIT}" \
  --set "service.type=ClusterIP" \
  --set "service.port=9093" \
  --set "config.global.resolve_timeout=5m" \
  --set "config.route.receiver=default" \
  --set "config.route.group_wait=30s" \
  --set "config.route.group_interval=5m" \
  --set "config.route.repeat_interval=4h" \
  --set "config.receivers[0].name=default" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for AlertManager failed (exit code ${HELM_EXIT})"
fi
log "  AlertManager Helm release '${RELEASE_NAME}' deployed."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== AlertManager Installation Summary ==="
echo "  Release:         ${RELEASE_NAME}"
echo "  Version:         ${ALERTMANAGER_VERSION}"
echo "  Namespace:       ${NAMESPACE}"
echo "  Service:         ClusterIP :9093"
echo "  Resources:       req ${AM_CPU_REQUEST}/${AM_MEM_REQUEST}, lim ${AM_CPU_LIMIT}/${AM_MEM_LIMIT}"
echo ""
echo "  Alerting rules:"
echo "    - Watchdog (always firing)"
echo "    - PodRestarting (rate > 1 restart/15m)"
echo "    - NodeMemoryPressure (< 10% available)"
echo "    - PodOOMKilled (OOMKilled reason detected)"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=alertmanager"
echo "    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME} 9093:9093 &"
echo "    curl http://localhost:9093/#/alerts"
echo "========================================"

log "install-alertmanager: completed successfully"
exit 0

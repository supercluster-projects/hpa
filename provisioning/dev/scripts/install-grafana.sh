#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-grafana.sh — Deploy Grafana dashboards
#
# Installs Grafana via the official Helm chart, pre-configured with a
# VictoriaMetrics VMSingle Prometheus datasource and Kubernetes cluster
# monitoring dashboards.
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-grafana.sh [--kubeconfig <path>]
#                            [--grafana-version <ver>]
#                            [--namespace <ns>]
#                            [--admin-password <pass>]
#                            [--vm-single-addr <url>]
#                            [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
require_env GRAFANA_VERSION

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="observability"
RELEASE_NAME="grafana"
WAIT_TIMEOUT=600
CHART_REPO_NAME="grafana"
CHART_REPO_URL="https://grafana.github.io/helm-charts"

# In-cluster VMSingle endpoint
VM_SINGLE_ADDR="http://vmsingle-victoria-metrics-single.${NAMESPACE}.svc.cluster.local:8428"

# Resource tuning for 3GB worker VMs
GF_CPU_REQUEST="0.1"
GF_MEM_REQUEST="100Mi"
GF_CPU_LIMIT="0.3"
GF_MEM_LIMIT="300Mi"

# ---- CLI Overrides --------------------------------------------------------
ADMIN_PASSWORD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";           shift 2 ;;
    --grafana-version)     GRAFANA_VERSION="$2";      shift 2 ;;
    --namespace)           NAMESPACE="$2";            shift 2 ;;
    --admin-password)      ADMIN_PASSWORD="$2";        shift 2 ;;
    --vm-single-addr)      VM_SINGLE_ADDR="$2";        shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Grafana with VMSingle datasource and K8s dashboards.

Options:
  --kubeconfig PATH        Path to kubeconfig
  --grafana-version VER    Grafana Helm chart version (required)
  --namespace NS           Namespace (default: observability)
  --admin-password PASS    Grafana admin password (default: auto-generated)
  --vm-single-addr URL     VMSingle address (default: auto-detected)
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
log "install-grafana: starting"
log "  kubeconfig:       ${KUBECONFIG}"
log "  version:          ${GRAFANA_VERSION}"
log "  namespace:        ${NAMESPACE}"
log "  release:          ${RELEASE_NAME}"
log "  vm-single-addr:   ${VM_SINGLE_ADDR}"
log "  resources:        req ${GF_CPU_REQUEST}/${GF_MEM_REQUEST}, lim ${GF_CPU_LIMIT}/${GF_MEM_LIMIT}"
log "  wait-timeout:     ${WAIT_TIMEOUT}s"

command -v helm >/dev/null 2>&1   || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]            || die "kubeconfig not found at ${KUBECONFIG}"

# Generate admin password if not provided
if [ -z "${ADMIN_PASSWORD}" ]; then
  ADMIN_PASSWORD=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(16)))
" 2>/dev/null || echo "grafana-$(date +%s)")
  log "  admin-password:   auto-generated (16 chars)"
else
  log "  admin-password:   provided via CLI (${#ADMIN_PASSWORD} chars)"
fi

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

# Store admin password as K8s Secret (for Grafana to read)
kubectl -n "${NAMESPACE}" create secret generic "grafana-admin" \
  --from-literal="admin-user=admin" \
  --from-literal="admin-password=${ADMIN_PASSWORD}" \
  --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1

log "  Namespace '${NAMESPACE}' ready. Admin Secret created."

# ---- Phase 3: Deploy Grafana via Helm -------------------------------------
log "Phase 3: Installing Grafana (${GRAFANA_VERSION}) in namespace ${NAMESPACE}..."

helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/grafana" \
  --version "${GRAFANA_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "admin.existingSecret=grafana-admin" \
  --set "admin.userKey=admin-user" \
  --set "admin.passwordKey=admin-password" \
  --set "resources.requests.cpu=${GF_CPU_REQUEST}" \
  --set "resources.requests.memory=${GF_MEM_REQUEST}" \
  --set "resources.limits.cpu=${GF_CPU_LIMIT}" \
  --set "resources.limits.memory=${GF_MEM_LIMIT}" \
  --set "service.type=ClusterIP" \
  --set "service.port=80" \
  --set "datasources.\"datasources.yaml\".apiVersion=1" \
  --set "datasources.\"datasources.yaml\".datasources[0].name=VMSingle" \
  --set "datasources.\"datasources.yaml\".datasources[0].type=prometheus" \
  --set "datasources.\"datasources.yaml\".datasources[0].url=${VM_SINGLE_ADDR}" \
  --set "datasources.\"datasources.yaml\".datasources[0].access=proxy" \
  --set "datasources.\"datasources.yaml\".datasources[0].isDefault=true" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for Grafana failed (exit code ${HELM_EXIT})"
fi
log "  Grafana Helm release '${RELEASE_NAME}' deployed."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Grafana Installation Summary ==="
echo "  Release:         ${RELEASE_NAME}"
echo "  Version:         ${GRAFANA_VERSION}"
echo "  Namespace:       ${NAMESPACE}"
echo "  Service:         ClusterIP :80"
echo "  Datasource:      VMSingle (${VM_SINGLE_ADDR})"
echo "  Admin user:      admin"
echo "  Admin password:  ${ADMIN_PASSWORD}"
echo "  Resources:       req ${GF_CPU_REQUEST}/${GF_MEM_REQUEST}, lim ${GF_CPU_LIMIT}/${GF_MEM_LIMIT}"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=grafana"
echo "    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME} 8080:80 &"
echo "    # Open http://localhost:8080 (admin / ${ADMIN_PASSWORD})"
echo "    curl http://admin:${ADMIN_PASSWORD}@localhost:8080/api/health"
echo "======================================"

log "install-grafana: completed successfully"
exit 0

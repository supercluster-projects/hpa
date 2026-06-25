#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-harbor.sh — Deploy Harbor OCI image registry on a Kubernetes cluster
#
# Installs Harbor via Helm with ceph-rbd PVCs for all persistence and a
# LoadBalancer Service (backed by S02's Cilium L2 pool) for external access.
# Uses bundled internal PostgreSQL and Redis.
#
# Idempotent: safe to re-run on an already-configured cluster (helm
# upgrade --atomic --wait is used).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-harbor.sh [--kubeconfig <path>] [--harbor-version <ver>]
#                            [--storage-class <name>] [--namespace <ns>]
#                            [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env HARBOR_VERSION
require_env HARBOR_ADMIN_PASSWORD
require_env DEV_STORAGE_CLASS

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="harbor"
WAIT_TIMEOUT=600
HELM_RELEASE_NAME="harbor"
STORAGE_CLASS="${DEV_STORAGE_CLASS}"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)      KUBECONFIG="$2";           shift 2 ;;
    --harbor-version)  HARBOR_VERSION="$2";        shift 2 ;;
    --storage-class)   STORAGE_CLASS="$2";         shift 2 ;;
    --namespace)       NAMESPACE="$2";             shift 2 ;;
    --wait-timeout)    WAIT_TIMEOUT="$2";           shift 2 ;;
    --admin-password)  HARBOR_ADMIN_PASSWORD="$2";  shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Harbor OCI image registry on a Kubernetes cluster with ceph-rbd
persistent storage and LoadBalancer exposure via Cilium L2.

Options:
  --kubeconfig PATH       Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --harbor-version VER    Harbor Helm chart version (default: 2.12.2)
  --storage-class NAME    StorageClass for PVCs (default: ceph-rbd)
  --namespace NS          Kubernetes namespace (default: harbor)
  --wait-timeout DUR      Timeout for Helm install and rollout (default: 10m)
  --admin-password PASS   Harbor admin password (default: random-generated; set via env var for production)
  --help, -h              Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-harbor: starting"
log "  kubeconfig:     ${KUBECONFIG}"
log "  harbor-version: ${HARBOR_VERSION}"
log "  storage-class:  ${STORAGE_CLASS}"
log "  namespace:      ${NAMESPACE}"
log "  wait-timeout:   ${WAIT_TIMEOUT}"

command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Step 1: Add/update Harbor Helm repo ----------------------------------
log "Step 1: Adding/updating Harbor Helm repo"
helm repo add harbor https://helm.goharbor.io --force-update > /dev/null 2>&1 \
  || die "Failed to add Harbor Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Harbor Helm repo: READY"

# ---- Step 2: Create namespace if it does not exist ------------------------
log "Step 2: Ensuring namespace '${NAMESPACE}' exists"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${NAMESPACE}'"
log "  Namespace '${NAMESPACE}': READY"

# ---- Step 3: Install/upgrade Harbor via Helm ------------------------------
log "Step 3: Installing/upgrading Harbor via Helm (version ${HARBOR_VERSION})"
helm upgrade --install "${HELM_RELEASE_NAME}" harbor/harbor \
  --namespace "${NAMESPACE}" \
  --version "${HARBOR_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set "expose.type=clusterIP" \
  --set "expose.tls.enabled=false" \
  --set "service.type=LoadBalancer" \
  --set "persistence.enabled=true" \
  --set "persistence.persistentVolumeClaim.registry.storageClass=${STORAGE_CLASS}" \
  --set "persistence.persistentVolumeClaim.jobservice.storageClass=${STORAGE_CLASS}" \
  --set "persistence.persistentVolumeClaim.database.storageClass=${STORAGE_CLASS}" \
  --set "persistence.persistentVolumeClaim.redis.storageClass=${STORAGE_CLASS}" \
  --set "persistence.persistentVolumeClaim.trivy.storageClass=${STORAGE_CLASS}" \
  --set "database.type=internal" \
  --set "redis.type=internal" \
  --set "harborAdminPassword=${HARBOR_ADMIN_PASSWORD}" \
  > /dev/null 2>&1 || die "Helm install/upgrade failed"
log "  Helm release '${HELM_RELEASE_NAME}': INSTALLED/UPGRADED"

# ---- Step 4: Wait for Harbor Deployment rollouts --------------------------
log "Step 4: Waiting for Harbor Deployment rollouts"
for deploy in harbor-core harbor-jobservice harbor-portal harbor-registry harbor-trivy; do
  if kubectl -n "${NAMESPACE}" get deployment "${deploy}" > /dev/null 2>&1; then
    kubectl -n "${NAMESPACE}" rollout status deployment/"${deploy}" \
      --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
      || die "Deployment '${deploy}' rollout did not complete within ${WAIT_TIMEOUT}"
    log "  Deployment '${deploy}': ROLLOUT COMPLETE"
  else
    log "  Deployment '${deploy}': NOT FOUND (skipping)"
  fi
done

# ---- Step 5: Check LoadBalancer IP assignment -----------------------------
log "Step 5: Checking LoadBalancer IP assignment"
LB_IP=""
for i in $(seq 1 30); do
  LB_IP=$(kubectl -n "${NAMESPACE}" get service "${HELM_RELEASE_NAME}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "${LB_IP}" ]; then
    log "  LoadBalancer IP: ${LB_IP}"
    break
  fi
  log "  Waiting for LoadBalancer IP (attempt ${i}/30)..."
  sleep 5
done
if [ -z "${LB_IP}" ]; then
  err "LoadBalancer IP was not assigned within the polling window"
  err "Check Cilium L2 pool and CiliumL2AnnouncementPolicy configuration"
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Harbor Installation Summary ==="
echo "  Harbor version:       ${HARBOR_VERSION}"
echo "  Helm release:         ${HELM_RELEASE_NAME} (namespace: ${NAMESPACE})"
echo "  Storage class:        ${STORAGE_CLASS}"
echo ""
echo "  Helm release status:"
helm status "${HELM_RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null \
  | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
  | sed 's/^/    /' || echo "    (unable to query)"
echo ""
echo "  PVCs:"
kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '{printf "    %-40s %-10s %s\n", $1, $5, $6}' \
  || echo "    (no PVCs found)"
echo ""
echo "  LoadBalancer IP:      ${LB_IP:-NOT ASSIGNED}"
echo "  Harbor URL:           http://${LB_IP:-<pending>}"
echo "  Admin user:           admin"
echo "  Admin password:       ${HARBOR_ADMIN_PASSWORD}"
echo ""
echo "==================================="

log "install-harbor: completed successfully"
exit 0

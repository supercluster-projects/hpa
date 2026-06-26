#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-casdoor.sh — Deploy Casdoor OIDC identity provider on a K8s cluster
#
# Installs PostgreSQL (Bitnami) on ceph-rbd, then Casdoor v3.100.0 from its
# official OCI Helm chart with PostgreSQL persistence and a LoadBalancer
# Service (backed by the Cilium L2 pool) for external/OIDC access.
#
# The bootstrap admin password is sourced from .env (CASDOOR_ADMIN_PASSWORD),
# stored in a temporary Secret ('casdoor-admin-secret'), injected into the
# Casdoor pod via envFromSecret. The bootstrap Secret is deleted after the
# install completes (Infisical bootstrap pattern).
#
# Idempotent: safe to re-run on an already-configured cluster (helm
# upgrade --atomic --wait is used for both PostgreSQL and Casdoor).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-casdoor.sh [--kubeconfig <path>] [--casdoor-version <ver>]
#                             [--storage-class <name>] [--namespace <ns>]
#                             [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Required environment variables (fail fast if missing from .env) ---
require_env CASDOOR_VERSION
require_env CASDOOR_ADMIN_PASSWORD
require_env DEV_STORAGE_CLASS

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="casdoor"
WAIT_TIMEOUT=600
PG_RELEASE_NAME="postgresql-casdoor"
CASDOOR_RELEASE_NAME="casdoor"
STORAGE_CLASS="${DEV_STORAGE_CLASS}"
PG_PASSWORD="${CASDOOR_ADMIN_PASSWORD}"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG="$2";               shift 2 ;;
    --casdoor-version)   CASDOOR_VERSION="$2";           shift 2 ;;
    --storage-class)     STORAGE_CLASS="$2";             shift 2 ;;
    --namespace)         NAMESPACE="$2";                 shift 2 ;;
    --wait-timeout)      WAIT_TIMEOUT="$2";              shift 2 ;;
    --admin-password)    PG_PASSWORD="$2";               shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Casdoor OIDC identity provider with PostgreSQL persistence and
LoadBalancer exposure via Cilium L2.

Options:
  --kubeconfig PATH       Path to kubeconfig (default: ../opentofu/kubeconfig)
  --casdoor-version VER   Casdoor Helm chart version (default: 3.100.0)
  --storage-class NAME    StorageClass for PVCs (default: ceph-rbd)
  --namespace NS          Kubernetes namespace (default: casdoor)
  --wait-timeout DUR      Timeout for Helm install and rollout (default: 10m)
  --admin-password PASS   PostgreSQL + Casdoor admin password (default: CASDOOR_ADMIN_PASSWORD env var)
  --help, -h              Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-casdoor: starting"
log "  kubeconfig:      ${KUBECONFIG}"
log "  casdoor-version: ${CASDOOR_VERSION}"
log "  storage-class:   ${STORAGE_CLASS}"
log "  namespace:       ${NAMESPACE}"
log "  wait-timeout:    ${WAIT_TIMEOUT}"
log "  pg-release:      ${PG_RELEASE_NAME}"
log "  casdoor-release: ${CASDOOR_RELEASE_NAME}"

command -v helm >/dev/null 2>&1    || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1  || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]             || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Step 1: Add Bitnami Helm repo for PostgreSQL -------------------------
log "Step 1: Adding Bitnami Helm repo"
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update > /dev/null 2>&1 \
  || die "Failed to add Bitnami Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Bitnami Helm repo: READY"

# ---- Step 2: Create namespace --------------------------------------------
log "Step 2: Ensuring namespace '${NAMESPACE}' exists"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${NAMESPACE}'"
log "  Namespace '${NAMESPACE}': READY"

# ---- Step 3: Install PostgreSQL via Bitnami Helm chart --------------------
log "Step 3: Installing PostgreSQL via Bitnami Helm chart"
helm upgrade --install "${PG_RELEASE_NAME}" bitnami/postgresql \
  --namespace "${NAMESPACE}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set "global.postgresql.auth.postgresPassword=${PG_PASSWORD}" \
  --set "global.postgresql.auth.username=casdoor" \
  --set "global.postgresql.auth.password=${PG_PASSWORD}" \
  --set "global.postgresql.auth.database=casdoor" \
  --set "primary.persistence.storageClass=${STORAGE_CLASS}" \
  --set "primary.persistence.size=1Gi" \
  --set "primary.persistence.enabled=true" \
  > /dev/null 2>&1 || die "PostgreSQL Helm install failed"
log "  PostgreSQL release '${PG_RELEASE_NAME}': INSTALLED"

# ---- Step 4: Wait for PostgreSQL StatefulSet rollout ----------------------
log "Step 4: Waiting for PostgreSQL StatefulSet rollout"
kubectl -n "${NAMESPACE}" rollout status statefulset "${PG_RELEASE_NAME}-postgresql" \
  --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
  || die "PostgreSQL StatefulSet rollout did not complete within ${WAIT_TIMEOUT}"
log "  PostgreSQL StatefulSet: ROLLOUT COMPLETE"

# ---- Step 5: Create bootstrap Secret with Casdoor admin password ----------
log "Step 5: Creating bootstrap Secret 'casdoor-admin-secret'"
kubectl -n "${NAMESPACE}" create secret generic "casdoor-admin-secret" \
  --from-literal="adminPassword=${PG_PASSWORD}" \
  --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to create bootstrap Secret"
log "  Bootstrap Secret 'casdoor-admin-secret': CREATED"

# ---- Step 6: Install/upgrade Casdoor via Helm -----------------------------
log "Step 6: Installing/upgrading Casdoor via Helm (version ${CASDOOR_VERSION})"
CASDOOR_PG_HOST="${PG_RELEASE_NAME}-postgresql.${NAMESPACE}.svc.cluster.local"

helm upgrade --install "${CASDOOR_RELEASE_NAME}" \
  oci://registry-1.docker.io/casbin/casdoor-helm-charts \
  --namespace "${NAMESPACE}" \
  --version "${CASDOOR_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set "database.driver=postgres" \
  --set "database.host=${CASDOOR_PG_HOST}" \
  --set "database.user=casdoor" \
  --set "database.password=${PG_PASSWORD}" \
  --set "database.databaseName=casdoor" \
  --set "database.sslMode=disable" \
  --set "service.type=LoadBalancer" \
  --set "service.port=8000" \
  --set "envFromSecret[0].name=CASDOOR_ADMIN_PASSWORD" \
  --set "envFromSecret[0].secretName=casdoor-admin-secret" \
  --set "envFromSecret[0].key=adminPassword" \
  > /dev/null 2>&1 || die "Casdoor Helm install failed"
log "  Casdoor release '${CASDOOR_RELEASE_NAME}': INSTALLED"

# ---- Step 7: Wait for Casdoor Deployment rollout --------------------------
log "Step 7: Waiting for Casdoor Deployment rollout"
kubectl -n "${NAMESPACE}" rollout status deployment "${CASDOOR_RELEASE_NAME}" \
  --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
  || die "Casdoor Deployment rollout did not complete within ${WAIT_TIMEOUT}"
log "  Casdoor Deployment: ROLLOUT COMPLETE"

# ---- Step 8: Check LoadBalancer IP assignment -----------------------------
log "Step 8: Checking LoadBalancer IP assignment"
LB_IP=""
for i in $(seq 1 30); do
  LB_IP=$(kubectl -n "${NAMESPACE}" get service "${CASDOOR_RELEASE_NAME}" \
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

# ---- Step 9: Delete bootstrap Secret (Infisical pattern) ------------------
log "Step 9: Deleting bootstrap Secret 'casdoor-admin-secret' (Infisical pattern)"
kubectl -n "${NAMESPACE}" delete secret "casdoor-admin-secret" --ignore-not-found=true > /dev/null 2>&1
log "  Bootstrap Secret deleted. Password is now managed by the environment."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Casdoor Installation Summary ==="
echo "  Casdoor version:      ${CASDOOR_VERSION}"
echo "  Helm release:         ${CASDOOR_RELEASE_NAME} (namespace: ${NAMESPACE})"
echo "  Storage class:        ${STORAGE_CLASS}"
echo "  PostgreSQL host:      ${CASDOOR_PG_HOST}"
echo ""
echo "  PostgreSQL Helm release status:"
helm status "${PG_RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null \
  | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
  | sed 's/^/    /' || echo "    (unable to query)"
echo ""
echo "  Casdoor Helm release status:"
helm status "${CASDOOR_RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null \
  | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
  | sed 's/^/    /' || echo "    (unable to query)"
echo ""
echo "  PVCs:"
kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '{printf "    %-40s %-10s %s\n", $1, $5, $6}' \
  || echo "    (no PVCs found)"
echo ""
echo "  LoadBalancer IP:      ${LB_IP:-NOT ASSIGNED}"
echo "  Casdoor URL:          http://${LB_IP:-<pending>}:8000"
echo "  Admin user:           admin"
echo "  Admin password:       ${PG_PASSWORD}"
echo "  API endpoint:         http://${LB_IP:-<pending>}:8000/api/login"
echo ""
echo "==================================="

log "install-casdoor: completed successfully"
exit 0

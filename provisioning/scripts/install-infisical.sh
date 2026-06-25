#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-infisical.sh — Deploy Infisical secrets management platform with
#                         Infisical Secrets Operator on a Kubernetes cluster
#
# Creates a bootstrap Kubernetes Secret from environment variables on the
# bootstrap machine, installs Infisical via Helm (referencing the bootstrap
# Secret), then deletes the bootstrap Secret after Infisical starts.
# Also installs the Infisical Secrets Operator in its own namespace.
#
# Idempotent: safe to re-run on an already-configured cluster (helm
# upgrade --atomic --wait is used).
# All logging goes to stderr; the final summary goes to stdout.
#
# Required environment variables (must be set before running):
#   INFISICAL_ENCRYPTION_KEY   — Encryption key for Infisical
#   INFISICAL_ADMIN_PASSWORD   — Admin password for Infisical
#   INFISICAL_AUTH_SECRET      — Auth secret for Infisical
#
# Usage: ./install-infisical.sh [--kubeconfig <path>] [--infisical-version <ver>]
#                               [--namespace <ns>] [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Defaults -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${SCRIPT_DIR}/../tofu-libvirt-dev/kubeconfig"
INFISICAL_VERSION=""  # chart default (latest stable)
NAMESPACE="infisical"
WAIT_TIMEOUT="10m"
HELM_RELEASE_NAME="infisical"
SECRETS_OP_NAMESPACE="infisical-secrets-operator"
SECRETS_OP_RELEASE="infisical-secrets-operator"
INFISICAL_HELM_REPO="https://dl.infisical.com/helm-charts"
BOOTSTRAP_SECRET_NAME="bootstrap-infisical"

# ---- Helpers --------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err() { log "ERROR: $*"; }
die() { err "$*"; exit 1; }

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG="$2";             shift 2 ;;
    --infisical-version) INFISICAL_VERSION="$2";      shift 2 ;;
    --namespace)         NAMESPACE="$2";               shift 2 ;;
    --wait-timeout)      WAIT_TIMEOUT="$2";            shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Infisical secrets management platform with Secrets Operator.

Required environment variables:
  INFISICAL_ENCRYPTION_KEY   Encryption key for Infisical
  INFISICAL_ADMIN_PASSWORD   Admin password for Infisical
  INFISICAL_AUTH_SECRET      Auth secret for Infisical

Options:
  --kubeconfig PATH       Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --infisical-version VER Infisical Helm chart version (default: latest stable)
  --namespace NS          Kubernetes namespace for Infisical (default: infisical)
  --wait-timeout DUR      Timeout for Helm install and rollout (default: 10m)
  --help, -h              Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-infisical: starting"
log "  kubeconfig:            ${KUBECONFIG}"
log "  infisical-version:     ${INFISICAL_VERSION:-latest stable}"
log "  namespace:             ${NAMESPACE}"
log "  secrets-op-namespace:  ${SECRETS_OP_NAMESPACE}"
log "  wait-timeout:          ${WAIT_TIMEOUT}"

command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# Verify required environment variables (do NOT log their values — redaction)
REQUIRED_VARS=(INFISICAL_ENCRYPTION_KEY INFISICAL_ADMIN_PASSWORD INFISICAL_AUTH_SECRET)
MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    MISSING_VARS+=("${var}")
  fi
done
if [ "${#MISSING_VARS[@]}" -gt 0 ]; then
  die "Required environment variables not set: ${MISSING_VARS[*]}"
fi
log "  Required env vars: all present"

# ---- Build Helm version flag ----------------------------------------------
HELM_VERSION_FLAGS=()
if [ -n "${INFISICAL_VERSION}" ]; then
  HELM_VERSION_FLAGS+=(--version "${INFISICAL_VERSION}")
fi

# ============================================================================
# Step 1: Add/update Infisical Helm repo
# ============================================================================
log "Step 1: Adding/updating Infisical Helm repo"
helm repo add infisical "${INFISICAL_HELM_REPO}" --force-update > /dev/null 2>&1 \
  || die "Failed to add Infisical Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Infisical Helm repo: READY"

# ============================================================================
# Step 2: Create bootstrap Kuberenetes Secret
# ============================================================================
log "Step 2: Creating bootstrap Secret '${BOOTSTRAP_SECRET_NAME}' in namespace '${NAMESPACE}'"

# Ensure the Infisical namespace exists first
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${NAMESPACE}'"

kubectl create secret generic "${BOOTSTRAP_SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal=encryptionKey="${INFISICAL_ENCRYPTION_KEY}" \
  --from-literal=adminPassword="${INFISICAL_ADMIN_PASSWORD}" \
  --from-literal=authSecret="${INFISICAL_AUTH_SECRET}" \
  --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to create bootstrap Secret '${BOOTSTRAP_SECRET_NAME}'"
log "  Bootstrap Secret '${BOOTSTRAP_SECRET_NAME}': CREATED"

# ============================================================================
# Step 3: Install/upgrade Infisical via Helm
# ============================================================================
log "Step 3: Installing/upgrading Infisical via Helm"
helm upgrade --install "${HELM_RELEASE_NAME}" infisical/infisical \
  --namespace "${NAMESPACE}" \
  "${HELM_VERSION_FLAGS[@]}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set "existingSecret=${BOOTSTRAP_SECRET_NAME}" \
  --set "existingSecretEncryptionKey=encryptionKey" \
  --set "existingSecretAdminPasswordKey=adminPassword" \
  --set "existingSecretAuthSecretKey=authSecret" \
  --set "service.type=LoadBalancer" \
  > /dev/null 2>&1 || die "Helm install/upgrade failed"
log "  Helm release '${HELM_RELEASE_NAME}': INSTALLED/UPGRADED"

# ============================================================================
# Step 4: Wait for Infisical Deployment rollouts
# ============================================================================
log "Step 4: Waiting for Infisical Deployment rollouts"
# Discover Infisical deployments dynamically (avoids hardcoding names)
INFISICAL_DEPLOYS=$(kubectl -n "${NAMESPACE}" get deployment \
  -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME}" -o name 2>/dev/null || true)
if [ -z "${INFISICAL_DEPLOYS}" ]; then
  # Fallback: get all deployments in the namespace
  INFISICAL_DEPLOYS=$(kubectl -n "${NAMESPACE}" get deployment -o name 2>/dev/null || true)
fi

for deploy_ref in ${INFISICAL_DEPLOYS}; do
  deploy_name="${deploy_ref#deployment.apps/}"
  kubectl -n "${NAMESPACE}" rollout status "deployment/${deploy_name}" \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || die "Deployment '${deploy_name}' rollout did not complete within ${WAIT_TIMEOUT}"
  log "  Deployment '${deploy_name}': ROLLOUT COMPLETE"
done

if [ -z "${INFISICAL_DEPLOYS}" ]; then
  log "  No Infisical deployments found — continuing (may be a Deployment-less chart)"
fi

# ============================================================================
# Step 5: Install/upgrade Infisical Secrets Operator via Helm
# ============================================================================
log "Step 5: Installing/upgrading Infisical Secrets Operator via Helm"

# Ensure the Secrets Operator namespace exists
kubectl create namespace "${SECRETS_OP_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${SECRETS_OP_NAMESPACE}'"

helm upgrade --install "${SECRETS_OP_RELEASE}" infisical/infisical-secrets-operator \
  --namespace "${SECRETS_OP_NAMESPACE}" \
  "${HELM_VERSION_FLAGS[@]}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  > /dev/null 2>&1 || die "Secrets Operator Helm install/upgrade failed"
log "  Helm release '${SECRETS_OP_RELEASE}': INSTALLED/UPGRADED"

# ============================================================================
# Step 6: Wait for Secrets Operator rollout
# ============================================================================
log "Step 6: Waiting for Secrets Operator Deployment rollout"
SECRETS_OP_DEPLOYS=$(kubectl -n "${SECRETS_OP_NAMESPACE}" get deployment \
  -l "app.kubernetes.io/instance=${SECRETS_OP_RELEASE}" -o name 2>/dev/null || true)
if [ -z "${SECRETS_OP_DEPLOYS}" ]; then
  SECRETS_OP_DEPLOYS=$(kubectl -n "${SECRETS_OP_NAMESPACE}" get deployment -o name 2>/dev/null || true)
fi

for deploy_ref in ${SECRETS_OP_DEPLOYS}; do
  deploy_name="${deploy_ref#deployment.apps/}"
  kubectl -n "${SECRETS_OP_NAMESPACE}" rollout status "deployment/${deploy_name}" \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || die "Secrets Operator deployment '${deploy_name}' rollout did not complete within ${WAIT_TIMEOUT}"
  log "  Secrets Operator Deployment '${deploy_name}': ROLLOUT COMPLETE"
done

if [ -z "${SECRETS_OP_DEPLOYS}" ]; then
  log "  No Secrets Operator deployments found — continuing"
fi

# ============================================================================
# Step 7: Delete the bootstrap Secret
# ============================================================================
log "Step 7: Deleting bootstrap Secret '${BOOTSTRAP_SECRET_NAME}' from namespace '${NAMESPACE}'"
kubectl delete secret "${BOOTSTRAP_SECRET_NAME}" -n "${NAMESPACE}" \
  --ignore-not-found=true > /dev/null 2>&1 \
  || die "Failed to delete bootstrap Secret '${BOOTSTRAP_SECRET_NAME}'"

# Verify deletion
SECRET_STILL_EXISTS=false
if kubectl get secret "${BOOTSTRAP_SECRET_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1; then
  SECRET_STILL_EXISTS=true
  err "Bootstrap Secret '${BOOTSTRAP_SECRET_NAME}' still exists after deletion attempt!"
fi

if [ "${SECRET_STILL_EXISTS}" = false ]; then
  log "  Bootstrap Secret '${BOOTSTRAP_SECRET_NAME}': DELETED"
fi

# ============================================================================
# Step 8: Check LoadBalancer IP assignment
# ============================================================================
log "Step 8: Checking Infisical LoadBalancer IP assignment"
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
BOOTSTRAP_SECRET_CURRENT_STATUS="DELETED"
if [ "${SECRET_STILL_EXISTS}" = true ]; then
  BOOTSTRAP_SECRET_CURRENT_STATUS="STILL PRESENT (cleanup failed)"
fi

echo ""
echo "=== Infisical Installation Summary ==="
echo "  Infisical version:    ${INFISICAL_VERSION:-latest stable}"
echo "  Helm release:         ${HELM_RELEASE_NAME} (namespace: ${NAMESPACE})"
echo "  Secrets Operator:     ${SECRETS_OP_RELEASE} (namespace: ${SECRETS_OP_NAMESPACE})"
echo ""
echo "  Helm release status:"
helm status "${HELM_RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null \
  | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
  | sed 's/^/    /' || echo "    (unable to query)"
echo ""
echo "  Secrets Operator status:"
helm status "${SECRETS_OP_RELEASE}" -n "${SECRETS_OP_NAMESPACE}" 2>/dev/null \
  | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
  | sed 's/^/    /' || echo "    (unable to query)"
echo ""
echo "  Bootstrap Secret:     ${BOOTSTRAP_SECRET_CURRENT_STATUS}"
echo "  LoadBalancer IP:      ${LB_IP:-NOT ASSIGNED}"
echo "  Infisical URL:        http://${LB_IP:-<pending>}"
echo ""
echo "======================================"

log "install-infisical: completed successfully"
exit 0

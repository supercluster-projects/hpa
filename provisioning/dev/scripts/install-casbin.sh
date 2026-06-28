#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-casbin.sh — Build and deploy Casbin gRPC ext_authz authorizer
#
# Delegates Docker image build and push to build-casbin.sh, then applies
# the Kubernetes manifests (Deployment, Service, ConfigMap) via Kustomize.
#
# The Casbin authorizer implements the Envoy ext_authz Authorization
# Check() RPC, supporting RBAC policies loaded from a ConfigMap.
#
# Idempotent: safe to re-run on an already-configured cluster (Docker
# build pushes a new image on each run; kustomize apply is declarative).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-casbin.sh [--kubeconfig <path>] [--casbin-version <ver>]
#                            [--namespace <ns>] [--kustomize-dir <dir>]
#                            [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Required environment variables (fail fast if missing from .env) ---
require_env CASBIN_VERSION
require_env DEV_HARBOR_URL
require_env DEV_HARBOR_PROJECT

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="casbin"
WAIT_TIMEOUT=600
DEPLOYMENT_NAME="casbin-ext-authz"
IMAGE_NAME="casbin-ext-authz"
HARBOR_HOST="${DEV_HARBOR_URL#*://}"
HARBOR_IMAGE="${HARBOR_HOST}/library/${DEV_HARBOR_PROJECT}/${IMAGE_NAME}"

# Relative to PROJECT_ROOT (set by preamble.sh)
KUSTOMIZE_DIR="gitops-workloads/authorizers/authz/base"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG="$2";               shift 2 ;;
    --casbin-version)    CASBIN_VERSION="$2";            shift 2 ;;
    --namespace)         NAMESPACE="$2";                 shift 2 ;;
    --kustomize-dir)     KUSTOMIZE_DIR="$2";             shift 2 ;;
    --wait-timeout)      WAIT_TIMEOUT="$2";              shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Build and deploy Casbin gRPC ext_authz authorizer on a Kubernetes cluster.

Steps:
  1  Build and push Docker image to Harbor (delegated to build-casbin.sh)
  2  Create namespace 'casbin' (idempotent)
  3  Apply Kubernetes manifests via Kustomize
  4  Wait for Deployment rollout
  5  Print summary

Options:
  --kubeconfig PATH         Path to kubeconfig (default: ../opentofu/kubeconfig)
  --casbin-version VER      Image tag / version (default: CASBIN_VERSION env var)
  --namespace NS            Kubernetes namespace (default: casbin)
  --kustomize-dir DIR       Kustomize base directory (default: gitops-workloads/authorizers/authz/base)
  --wait-timeout DUR        Timeout for rollout (default: 10m)
  --help, -h                Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Resolve paths relative to PROJECT_ROOT ------------------------------
BUILD_SCRIPT="${SCRIPT_DIR}/build-casbin.sh"
KUSTOMIZE_ABS="${PROJECT_ROOT}/${KUSTOMIZE_DIR}"

# ---- Preflight Checks -----------------------------------------------------
log "install-casbin: starting"
log "  kubeconfig:        ${KUBECONFIG}"
log "  casbin-version:    ${CASBIN_VERSION}"
log "  namespace:         ${NAMESPACE}"
log "  harbor url:        ${DEV_HARBOR_URL}"
log "  harbor image:      ${HARBOR_IMAGE}:${CASBIN_VERSION}"
log "  kustomize dir:     ${KUSTOMIZE_ABS}"
log "  wait timeout:      ${WAIT_TIMEOUT}"

command -v kubectl >/dev/null 2>&1   || die "kubectl not found in PATH"
command -v kustomize >/dev/null 2>&1  || die "kustomize not found in PATH (try 'kubectl kustomize')"
[ -f "${KUBECONFIG}" ]               || die "kubeconfig not found at ${KUBECONFIG}"
[ -f "${BUILD_SCRIPT}" ]             || die "build-casbin.sh not found at ${BUILD_SCRIPT}"
[ -d "${KUSTOMIZE_ABS}" ]            || die "Kustomize directory not found at ${KUSTOMIZE_ABS}"
[ -f "${KUSTOMIZE_ABS}/kustomization.yaml" ] || die "kustomization.yaml not found in ${KUSTOMIZE_ABS}"

# ============================================================================
# Step 1: Build and push Docker image via build-casbin.sh
# ============================================================================
log "Step 1: Building and pushing Casbin image to Harbor via build-casbin.sh"
"${BUILD_SCRIPT}" --image-tag "${CASBIN_VERSION}" > /dev/null 2>&1 || die "build-casbin.sh failed"
log "  build-casbin.sh: SUCCESS"

# ============================================================================
# Step 2: Create namespace
# ============================================================================
log "Step 2: Ensuring namespace '${NAMESPACE}' exists"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${NAMESPACE}'"
log "  Namespace '${NAMESPACE}': READY"

# ============================================================================
# Step 3: Apply Kustomize manifests
# ============================================================================
log "Step 3: Applying Casbin manifests via Kustomize"

# Use standalone kustomize first, fallback to kubectl kustomize
if ! kustomize build "${KUSTOMIZE_ABS}" > /dev/null 2>&1; then
  log "  kustomize build via standalone failed, trying kubectl kustomize..."
  if ! kubectl kustomize "${KUSTOMIZE_ABS}" > /dev/null 2>&1; then
    die "Failed to build Kustomize overlay at '${KUSTOMIZE_ABS}'"
  fi
  kubectl kustomize "${KUSTOMIZE_ABS}" | kubectl apply -f - > /dev/null 2>&1 \
    || die "Failed to apply Kustomize manifests for Casbin"
else
  kustomize build "${KUSTOMIZE_ABS}" | kubectl apply -f - > /dev/null 2>&1 \
    || die "Failed to apply Kustomize manifests for Casbin"
fi
log "  Casbin manifests: APPLIED"

# ============================================================================
# Step 4: Wait for Deployment rollout
# ============================================================================
log "Step 4: Waiting for Deployment '${DEPLOYMENT_NAME}' rollout"
kubectl -n "${NAMESPACE}" rollout status deployment/"${DEPLOYMENT_NAME}" \
  --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
  || die "Deployment '${DEPLOYMENT_NAME}' rollout did not complete within ${WAIT_TIMEOUT}"
log "  Deployment '${DEPLOYMENT_NAME}': ROLLOUT COMPLETE"

# ============================================================================
# Step 5: Gather component statuses for summary
# ============================================================================
log "Step 5: Gathering component statuses"

# Deployment status
DEPLOY_READY=$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT_NAME}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DEPLOY_DESIRED=$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT_NAME}" \
  -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")

# Service endpoint
SVC_CLUSTER_IP=$(kubectl -n "${NAMESPACE}" get service "${DEPLOYMENT_NAME}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "Not assigned")
SVC_PORT=$(kubectl -n "${NAMESPACE}" get service "${DEPLOYMENT_NAME}" \
  -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "9001")

# ConfigMap keys
CM_KEYS=""
if kubectl -n "${NAMESPACE}" get configmap casbin-config > /dev/null 2>&1; then
  CM_KEYS=$(kubectl -n "${NAMESPACE}" get configmap casbin-config \
    -o jsonpath='{.data}' 2>/dev/null | grep -oE '"[^"]+":' | tr -d '":' | tr '\n' ' ' || echo "casbin_model.conf casbin_policy.csv")
fi

# Pod status
PODS_TOTAL=$(kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null | wc -l)
PODS_READY=$(kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null | awk '{print $2}' | awk -F'/' '{if ($1==$2) print}' | wc -l || echo "0")

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Casbin Installation Summary ==="
echo "  Image:                ${HARBOR_IMAGE}:${CASBIN_VERSION}"
echo "  Namespace:            ${NAMESPACE}"
echo ""
echo "  Deployment:"
echo "    name:               ${DEPLOYMENT_NAME}"
echo "    ready:              ${DEPLOY_READY:-0}/${DEPLOY_DESIRED:-0}"
echo ""
echo "  Service:"
echo "    name:               ${DEPLOYMENT_NAME}"
echo "    type:               ClusterIP"
echo "    cluster IP:         ${SVC_CLUSTER_IP}"
echo "    port:               ${SVC_PORT} (gRPC)"
echo "    endpoint:           ${DEPLOYMENT_NAME}.${NAMESPACE}.svc.cluster.local:${SVC_PORT}"
echo ""
echo "  ConfigMap:"
echo "    name:               casbin-config"
echo "    keys:               ${CM_KEYS:-<not found>}"
echo ""
echo "  Pods:"
kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null \
  | awk '{printf "    %-45s %-10s %-10s %s\n", $1, $2, $3, $4}' \
  || echo "    (no pods found)"
echo ""
echo "  Kustomize:            ${KUSTOMIZE_ABS}"
echo "  Build script:         provisioning/dev/scripts/build-casbin.sh"
echo ""
echo "==================================="

log "install-casbin: completed successfully"
exit 0

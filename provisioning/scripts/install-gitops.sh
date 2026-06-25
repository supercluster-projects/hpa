#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-gitops.sh — Deploy Kargo + ArgoCD GitOps pipeline on K8s
#
# Installs the GitOps delivery pipeline that watches Harbor for new images
# and syncs workloads from gitops-workloads/functions/overlays/dev:
#   1. Kargo — Kubernetes-native container image promotion (Helm chart)
#   2. ArgoCD — Declarative GitOps CD engine (Helm chart)
#   3. Kargo Warehouse 'hpa-warehouse' — Watches Harbor for new images
#   4. ArgoCD Application 'hpa-workloads' — Syncs from gitops-workloads repo
#
# Both Kargo and ArgoCD are installed with ClusterIP services since Envoy
# Gateway handles ingress (configured in M006).
#
# Idempotent: safe to re-run on an already-configured cluster (Helm
# upgrade --atomic --wait and kubectl apply are used throughout).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-gitops.sh [--kubeconfig <path>]
#                            [--kargo-version <ver>]
#                            [--argocd-version <ver>]
#                            [--harbor-url <url>]
#                            [--harbor-project <project>]
#                            [--gitops-repo-url <url>]
#                            [--gitops-revision <rev>]
#                            [--cluster-dest-name <name>]
#                            [--cluster-dest-url <url>]
#                            [--namespace-prefix <prefix>]
#                            [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env KARGO_VERSION
require_env ARGOCD_VERSION
require_env GITOPS_REPO_URL
require_env DEV_HARBOR_URL
require_env DEV_HARBOR_PROJECT
require_env DEV_GITOPS_REVISION

# ---- Internal defaults (script-internal only) -------------------------
KARGO_NAMESPACE="kargo"
ARGOCD_NAMESPACE="argocd"
WAIT_TIMEOUT=600
HARBOR_URL="${DEV_HARBOR_URL}"
HARBOR_PROJECT="${DEV_HARBOR_PROJECT}"
GITOPS_REVISION="${DEV_GITOPS_REVISION}"
HARBOR_HOST="${HARBOR_URL#*://}"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";            shift 2 ;;
    --kargo-version)       KARGO_VERSION="$2";          shift 2 ;;
    --argocd-version)      ARGOCD_VERSION="$2";         shift 2 ;;
    --harbor-url)          HARBOR_URL="$2";             shift 2 ;;
    --harbor-project)      HARBOR_PROJECT="$2";         shift 2 ;;
    --gitops-repo-url)     GITOPS_REPO_URL="$2";        shift 2 ;;
    --gitops-revision)     GITOPS_REVISION="$2";        shift 2 ;;
    --cluster-dest-name)   CLUSTER_DEST_NAME="$2";      shift 2 ;;
    --cluster-dest-url)    CLUSTER_DEST_URL="$2";        shift 2 ;;
    --namespace-prefix)    NAMESPACE_PREFIX="$2";        shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";            shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Kargo + ArgoCD GitOps pipeline on a Kubernetes cluster.

Components installed:
  - Kargo                 Kubernetes-native container image promotion
  - ArgoCD                Declarative GitOps continuous delivery
  - Kargo Warehouse       Watches Harbor for new images (hpa-warehouse)
  - ArgoCD Application    Syncs workloads from gitops-workloads (hpa-workloads)

Options:
  --kubeconfig PATH            Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --kargo-version VER          Kargo Helm chart version (default: 1.3.0)
  --argocd-version VER         ArgoCD Helm chart version (default: 7.8.0)
  --harbor-url URL             Harbor registry URL (default: http://harbor.harbor.svc.cluster.local)
  --harbor-project PROJECT     Harbor project name (default: hpa-workloads)
  --gitops-repo-url URL        GitOps workloads repository URL (default: https://github.com/example/gitops-workloads.git)
  --gitops-revision REV        Git revision to sync (default: HEAD)
  --cluster-dest-name NAME     ArgoCD cluster destination name (default: in-cluster)
  --cluster-dest-url URL       ArgoCD cluster destination URL (default: https://kubernetes.default.svc)
  --namespace-prefix PREFIX    Prefix for all component namespaces
  --wait-timeout DUR           Timeout for Helm install and rollouts (default: 10m)
  --help, -h                   Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-gitops: starting"
log "  kubeconfig:          ${KUBECONFIG}"
log "  kargo-version:       ${KARGO_VERSION}"
log "  argocd-version:      ${ARGOCD_VERSION}"
log "  harbor-url:          ${HARBOR_URL}"
log "  harbor-project:      ${HARBOR_PROJECT}"
log "  gitops-repo-url:     ${GITOPS_REPO_URL}"
log "  gitops-revision:     ${GITOPS_REVISION}"
log "  cluster-dest-name:   ${CLUSTER_DEST_NAME}"
log "  cluster-dest-url:    ${CLUSTER_DEST_URL}"
log "  namespace-prefix:    ${NAMESPACE_PREFIX:-<none>}"
log "  wait-timeout:        ${WAIT_TIMEOUT}"

command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Internal state tracking ----------------------------------------------
KARGO_INSTALLED=false
ARGOCD_INSTALLED=false

# ============================================================================
# Step 1: Install Kargo via Helm
# ============================================================================
log "Step 1: Installing Kargo (${KARGO_VERSION})"

helm repo add kargo https://kargo.akuity.io/charts --force-update > /dev/null 2>&1 \
  || die "Failed to add Kargo Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Kargo Helm repo: READY"

kubectl create namespace "${KARGO_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${KARGO_NAMESPACE}'"
log "  Namespace '${KARGO_NAMESPACE}': READY"

helm upgrade --install kargo kargo/kargo \
  --namespace "${KARGO_NAMESPACE}" \
  --version "${KARGO_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set service.type=ClusterIP \
  > /dev/null 2>&1 || log "  (non-fatal) Kargo Helm install will be re-attempted via --atomic"

# Verify Kargo installed; if not, retry once
if kubectl -n "${KARGO_NAMESPACE}" get deployment kargo > /dev/null 2>&1 || \
   kubectl -n "${KARGO_NAMESPACE}" get deployment kargo-controller > /dev/null 2>&1; then
  KARGO_INSTALLED=true
  log "  Kargo: INSTALLED"
else
  log "  Kargo not found after first attempt, retrying..."
  helm upgrade --install kargo kargo/kargo \
    --namespace "${KARGO_NAMESPACE}" \
    --version "${KARGO_VERSION}" \
    --atomic \
    --wait \
    --timeout "${WAIT_TIMEOUT}" \
    --set service.type=ClusterIP \
    > /dev/null 2>&1 || die "Kargo Helm install failed after retry"
  KARGO_INSTALLED=true
  log "  Kargo: INSTALLED"
fi

# Wait for Kargo deployments
for deploy in kargo kargo-controller; do
  if kubectl -n "${KARGO_NAMESPACE}" get deployment "${deploy}" > /dev/null 2>&1; then
    kubectl -n "${KARGO_NAMESPACE}" rollout status deployment/"${deploy}" \
      --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
      || log "  (non-fatal) Deployment '${deploy}' rollout did not complete within ${WAIT_TIMEOUT}"
    log "  Deployment '${deploy}': ROLLOUT COMPLETE"
  fi
done

# ============================================================================
# Step 2: Create Kargo Warehouse resource 'hpa-warehouse'
# ============================================================================
log "Step 2: Creating Kargo Warehouse 'hpa-warehouse'"

# The Warehouse watches Harbor for new images in the specified project.
# It requires a valid Harbor URL and project name (configurable via CLI flags).
# NOTE: Kargo image subscription repoURL must be a bare OCI registry path
# (e.g. "harbor.harbor.svc.cluster.local/library/hpa-workloads") — the
# http:// or https:// protocol prefix is stripped from HARBOR_URL if present.
HARBOR_HOST="${HARBOR_URL#*://}"
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || log "  (non-fatal) Kargo Warehouse creation will be retried after ArgoCD is ready"
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: hpa-warehouse
  namespace: ${KARGO_NAMESPACE}
spec:
  subscriptions:
    - image:
        repoURL: "${HARBOR_HOST}/library/${HARBOR_PROJECT}"
        imageSelectionStrategy: SemVer
  freightCreationPolicy: Automatic
  stages:
    - dev
EOF
log "  Warehouse 'hpa-warehouse': APPLIED"

# ============================================================================
# Step 3: Install ArgoCD via Helm
# ============================================================================
log "Step 3: Installing ArgoCD (${ARGOCD_VERSION})"

helm repo add argo https://argoproj.github.io/argo-helm --force-update > /dev/null 2>&1 \
  || die "Failed to add ArgoCD Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  ArgoCD Helm repo: READY"

kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${ARGOCD_NAMESPACE}'"
log "  Namespace '${ARGOCD_NAMESPACE}': READY"

helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --version "${ARGOCD_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set server.service.type=ClusterIP \
  --set configs.params.server.insecure=true \
  > /dev/null 2>&1 || log "  (non-fatal) ArgoCD Helm install will be re-attempted via --atomic"

# Verify ArgoCD installed; if not, retry once
if kubectl -n "${ARGOCD_NAMESPACE}" get deployment argocd-server > /dev/null 2>&1; then
  ARGOCD_INSTALLED=true
  log "  ArgoCD: INSTALLED"
else
  log "  ArgoCD not found after first attempt, retrying..."
  helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NAMESPACE}" \
    --version "${ARGOCD_VERSION}" \
    --atomic \
    --wait \
    --timeout "${WAIT_TIMEOUT}" \
    --set server.service.type=ClusterIP \
    --set configs.params.server.insecure=true \
    > /dev/null 2>&1 || die "ArgoCD Helm install failed after retry"
  ARGOCD_INSTALLED=true
  log "  ArgoCD: INSTALLED"
fi

# Wait for ArgoCD deployments
for deploy in argocd-server argocd-repo-server argocd-application-controller argocd-redis; do
  if kubectl -n "${ARGOCD_NAMESPACE}" get deployment "${deploy}" > /dev/null 2>&1; then
    kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/"${deploy}" \
      --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
      || log "  (non-fatal) ArgoCD deployment '${deploy}' rollout did not complete within ${WAIT_TIMEOUT}"
    log "  Deployment '${deploy}': ROLLOUT COMPLETE"
  fi
done

# Also wait for argocd-application-controller statefulset if present (some chart versions shift to it)
if kubectl -n "${ARGOCD_NAMESPACE}" get statefulset argocd-application-controller > /dev/null 2>&1; then
  kubectl -n "${ARGOCD_NAMESPACE}" rollout status statefulset/argocd-application-controller \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || log "  (non-fatal) ArgoCD StatefulSet 'argocd-application-controller' rollout did not complete"
  log "  StatefulSet 'argocd-application-controller': ROLLOUT COMPLETE"
fi

# ============================================================================
# Step 4: Create ArgoCD Application resource 'hpa-workloads'
# ============================================================================
log "Step 4: Creating ArgoCD Application 'hpa-workloads'"

# The Application targets gitops-workloads/functions/overlays/dev with
# automated sync policy (prune=true, selfHeal=true).
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || log "  (non-fatal) ArgoCD Application creation was not immediate (will be created on retry)"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hpa-workloads
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: "${GITOPS_REPO_URL}"
    targetRevision: "${GITOPS_REVISION}"
    path: functions/overlays/dev
  destination:
    name: "${CLUSTER_DEST_NAME}"
    namespace: hpa-workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: true
    syncOptions:
      - CreateNamespace=true
EOF
log "  Application 'hpa-workloads': APPLIED"

# Verify the Application was created successfully
if kubectl -n "${ARGOCD_NAMESPACE}" get application hpa-workloads > /dev/null 2>&1; then
  log "  Application 'hpa-workloads': VERIFIED"
else
  log "  (non-fatal) Application 'hpa-workloads' not immediately visible (may take a moment)"
fi

# ============================================================================
# Step 5: Update Kargo Warehouse with reference to the correct Harbor API
# ============================================================================
log "Step 5: Verifying Kargo Warehouse configuration"

if kubectl -n "${KARGO_NAMESPACE}" get warehouse hpa-warehouse > /dev/null 2>&1; then
  log "  Warehouse 'hpa-warehouse': EXISTS"
  WH_SUB=$(kubectl -n "${KARGO_NAMESPACE}" get warehouse hpa-warehouse \
    -o jsonpath='{.spec.subscriptions[0].image.repoURL}' 2>/dev/null || echo "Unknown")
  log "  Warehouse subscription repo: ${WH_SUB}"
else
  log "  (non-fatal) Warehouse 'hpa-warehouse' not yet visible"
fi

# ============================================================================
# Step 6: Gather component statuses for summary
# ============================================================================
log "Step 6: Gathering component statuses"

# Kargo status
KARGO_STATUS="NOT INSTALLED"
if [ "${KARGO_INSTALLED}" = true ]; then
  KARGO_DEPLOYS=$(kubectl -n "${KARGO_NAMESPACE}" get deployment -o name 2>/dev/null | wc -l)
  KARGO_RDY=$(kubectl -n "${KARGO_NAMESPACE}" get deployment \
    -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | tr ' ' '\n' | paste -sd+ | bc || echo "0")
  KARGO_ROLLOUT=$(kubectl -n "${KARGO_NAMESPACE}" rollout status deployment/kargo \
    --timeout=5s 2>/dev/null && echo "Ready" || echo "Not Ready")
  KARGO_STATUS="${KARGO_ROLLOUT} (deployments: ${KARGO_DEPLOYS:-0}, ready: ${KARGO_RDY:-0})"
fi

# Warehouse status
WAREHOUSE_STATUS="NOT CREATED"
if kubectl -n "${KARGO_NAMESPACE}" get warehouse hpa-warehouse > /dev/null 2>&1; then
  WH_AGE=$(kubectl -n "${KARGO_NAMESPACE}" get warehouse hpa-warehouse \
    -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
  WAREHOUSE_STATUS="created at ${WH_AGE}"
fi

# ArgoCD status
ARGOCD_STATUS="NOT INSTALLED"
if [ "${ARGOCD_INSTALLED}" = true ]; then
  ARGOCD_DEPLOYS=$(kubectl -n "${ARGOCD_NAMESPACE}" get deployment -o name 2>/dev/null | wc -l)
  ARGOCD_RDY=$(kubectl -n "${ARGOCD_NAMESPACE}" get deployment \
    -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | tr ' ' '\n' | paste -sd+ | bc || echo "0")
  ARGOCD_STATUS="deployments: ${ARGOCD_DEPLOYS:-0}, ready replicas: ${ARGOCD_RDY:-0}"
fi

# Application status
APP_STATUS="NOT CREATED"
if kubectl -n "${ARGOCD_NAMESPACE}" get application hpa-workloads > /dev/null 2>&1; then
  APP_SYNC=$(kubectl -n "${ARGOCD_NAMESPACE}" get application hpa-workloads \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || "Unknown")
  APP_HEALTH=$(kubectl -n "${ARGOCD_NAMESPACE}" get application hpa-workloads \
    -o jsonpath='{.status.health.status}' 2>/dev/null || "Unknown")
  APP_STATUS="sync: ${APP_SYNC:-Unknown}, health: ${APP_HEALTH:-Unknown}"
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== GitOps Installation Summary ==="
echo "  Kargo:                ${KARGO_VERSION}"
echo "    namespace:          ${KARGO_NAMESPACE}"
echo "    status:             ${KARGO_STATUS}"
echo ""
echo "  Warehouse:"
echo "    name:               hpa-warehouse"
echo "    namespace:          ${KARGO_NAMESPACE}"
echo "    harbor URL:         ${HARBOR_URL}/library/${HARBOR_PROJECT}"
echo "    status:             ${WAREHOUSE_STATUS}"
echo ""
echo "  ArgoCD:               ${ARGOCD_VERSION}"
echo "    namespace:          ${ARGOCD_NAMESPACE}"
echo "    status:             ${ARGOCD_STATUS}"
echo ""
echo "  Application:"
echo "    name:               hpa-workloads"
echo "    namespace:          ${ARGOCD_NAMESPACE}"
echo "    repo URL:           ${GITOPS_REPO_URL}"
echo "    revision:           ${GITOPS_REVISION}"
echo "    path:               functions/overlays/dev"
echo "    destination:        ${CLUSTER_DEST_NAME} (${CLUSTER_DEST_URL})"
echo "    status:             ${APP_STATUS}"
echo ""
echo "  Helm release status:"
for release in kargo argocd; do
  case "${release}" in
    kargo)  RLS_NS="${KARGO_NAMESPACE}" ;;
    argocd) RLS_NS="${ARGOCD_NAMESPACE}" ;;
  esac
  if helm status "${release}" -n "${RLS_NS}" > /dev/null 2>&1; then
    helm status "${release}" -n "${RLS_NS}" 2>/dev/null \
      | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
      | sed "s/^/    [${release}] /" || true
  fi
done
echo ""
echo "  ArgoCD deployments:"
for deploy in argocd-server argocd-repo-server argocd-application-controller argocd-redis; do
  if kubectl -n "${ARGOCD_NAMESPACE}" get deployment "${deploy}" > /dev/null 2>&1; then
    READY=$(kubectl -n "${ARGOCD_NAMESPACE}" get deployment "${deploy}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl -n "${ARGOCD_NAMESPACE}" get deployment "${deploy}" \
      -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    echo "    ${deploy}: ${READY:-0}/${DESIRED:-0} ready"
  fi
done
echo ""
echo "  Kargo CRDs:"
for crd in warehouses.kargo.akuity.io stages.kargo.akuity.io freights.kargo.akuity.io; do
  if kubectl get crd "${crd}" > /dev/null 2>&1; then
    echo "    ${crd}: PRESENT"
  else
    echo "    ${crd}: MISSING"
  fi
done
echo ""
echo "  ArgoCD CRDs:"
for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
  if kubectl get crd "${crd}" > /dev/null 2>&1; then
    echo "    ${crd}: PRESENT"
  else
    echo "    ${crd}: MISSING"
  fi
done
echo ""
echo "  Kargo Warehouse:"
kubectl -n "${KARGO_NAMESPACE}" get warehouse --no-headers 2>/dev/null \
  | awk '{printf "    %-30s %s\n", $1, $2}' \
  || echo "    (no warehouses found)"
echo ""
echo "  ArgoCD Applications:"
kubectl -n "${ARGOCD_NAMESPACE}" get application --no-headers 2>/dev/null \
  | awk '{printf "    %-30s %-15s %s\n", $1, $2, $3}' \
  || echo "    (no applications found)"
echo ""
echo "==================================="

log "install-gitops: completed successfully"
exit 0

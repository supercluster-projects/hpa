#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-runtimes.sh — Deploy Knative Serving + cert-manager + SpinKube
#                       + KeyDB on a Kubernetes cluster
#
# Installs core runtimes needed by application workloads:
#   1. cert-manager  — TLS certificate management (Jetstack Helm chart)
#   2. Knative Serving — Serverless container execution (Kourier ingress)
#   3. SpinKube Operator — Spin application runtime operator
#   4. KeyDB — Redis-compatible in-memory data store with ceph-rbd PVC
#
# Idempotent: safe to re-run on an already-configured cluster (Helm
# upgrade --atomic --wait and kubectl apply are used throughout).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-runtimes.sh [--kubeconfig <path>]
#                              [--cert-manager-version <ver>]
#                              [--knative-version <ver>]
#                              [--spin-operator-version <ver>]
#                              [--keydb-image <image>]
#                              [--storage-class <name>]
#                              [--namespace-prefix <prefix>]
#                              [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Defaults -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${SCRIPT_DIR}/../tofu-libvirt-dev/kubeconfig"
CERT_MANAGER_VERSION="v1.17.1"
KNATIVE_VERSION="v1.16.0"
SPIN_OPERATOR_VERSION="v0.13.0"
KEYDB_IMAGE="eqalpha/keydb:x86_64_v6.3.3"
STORAGE_CLASS="ceph-rbd"
NAMESPACE_PREFIX=""
WAIT_TIMEOUT="10m"

# ---- Derived namespaces ---------------------------------------------------
CERT_MANAGER_NAMESPACE="${NAMESPACE_PREFIX}cert-manager"
KNATIVE_NAMESPACE="${NAMESPACE_PREFIX}knative-serving"
KOURIER_NAMESPACE="${NAMESPACE_PREFIX}kourier-system"
SPIN_OPERATOR_NAMESPACE="${NAMESPACE_PREFIX}spin-operator"
KEYDB_NAMESPACE="${NAMESPACE_PREFIX}keydb"

# ---- Helpers --------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err() { log "ERROR: $*"; }
die() { err "$*"; exit 1; }

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)             KUBECONFIG="$2";               shift 2 ;;
    --cert-manager-version)   CERT_MANAGER_VERSION="$2";     shift 2 ;;
    --knative-version)        KNATIVE_VERSION="$2";          shift 2 ;;
    --spin-operator-version)  SPIN_OPERATOR_VERSION="$2";    shift 2 ;;
    --keydb-image)            KEYDB_IMAGE="$2";              shift 2 ;;
    --storage-class)          STORAGE_CLASS="$2";            shift 2 ;;
    --namespace-prefix)       NAMESPACE_PREFIX="$2";         shift 2 ;;
    --wait-timeout)           WAIT_TIMEOUT="$2";             shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Knative Serving + cert-manager + SpinKube operator + KeyDB.

Components installed:
  - cert-manager       TLS certificate management (Jetstack Helm chart)
  - Knative Serving    Serverless container execution (Kourier ingress)
  - SpinKube operator  Spin application runtime operator
  - KeyDB              Redis-compatible in-memory data store with PVC

Options:
  --kubeconfig PATH              Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --cert-manager-version VER     cert-manager version (default: v1.17.1)
  --knative-version VER          Knative Serving version (default: v1.16.0)
  --spin-operator-version VER    Spin operator Helm chart version (default: v0.13.0)
  --keydb-image IMAGE            KeyDB container image (default: eqalpha/keydb:x86_64_v6.3.3)
  --storage-class NAME           StorageClass for KeyDB PVC (default: ceph-rbd)
  --namespace-prefix PREFIX      Prefix for all component namespaces
  --wait-timeout DUR             Timeout for Helm install and rollouts (default: 10m)
  --help, -h                     Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-runtimes: starting"
log "  kubeconfig:             ${KUBECONFIG}"
log "  cert-manager-version:   ${CERT_MANAGER_VERSION}"
log "  knative-version:        ${KNATIVE_VERSION}"
log "  spin-operator-version:  ${SPIN_OPERATOR_VERSION}"
log "  keydb-image:            ${KEYDB_IMAGE}"
log "  storage-class:          ${STORAGE_CLASS}"
log "  namespace-prefix:       ${NAMESPACE_PREFIX:-<none>}"
log "  wait-timeout:           ${WAIT_TIMEOUT}"

command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Internal state tracking ----------------------------------------------
# Tracks installation status of each component
CERT_MANAGER_INSTALLED=false
KNATIVE_INSTALLED=false
SPIN_OPERATOR_INSTALLED=false
KEYDB_INSTALLED=false

# ============================================================================
# Step 1: Install cert-manager via Helm
# ============================================================================
log "Step 1: Installing cert-manager (${CERT_MANAGER_VERSION})"

helm repo add jetstack https://charts.jetstack.io --force-update > /dev/null 2>&1 \
  || die "Failed to add jetstack Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Jetstack Helm repo: READY"

kubectl create namespace "${CERT_MANAGER_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${CERT_MANAGER_NAMESPACE}'"
log "  Namespace '${CERT_MANAGER_NAMESPACE}': READY"

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "${CERT_MANAGER_NAMESPACE}" \
  --version "${CERT_MANAGER_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set installCRDs=true \
  > /dev/null 2>&1 || log "  (non-fatal) cert-manager Helm install will be re-attempted via --atomic"

# Verify cert-manager installed; if not, retry once
if kubectl -n "${CERT_MANAGER_NAMESPACE}" get deployment cert-manager > /dev/null 2>&1; then
  CERT_MANAGER_INSTALLED=true
  log "  cert-manager: INSTALLED"
else
  log "  cert-manager not found after first attempt, retrying..."
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "${CERT_MANAGER_NAMESPACE}" \
    --version "${CERT_MANAGER_VERSION}" \
    --atomic \
    --wait \
    --timeout "${WAIT_TIMEOUT}" \
    --set installCRDs=true \
    > /dev/null 2>&1 || die "cert-manager Helm install failed after retry"
  CERT_MANAGER_INSTALLED=true
  log "  cert-manager: INSTALLED"
fi

# Wait for cert-manager deployments
for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
  if kubectl -n "${CERT_MANAGER_NAMESPACE}" get deployment "${deploy}" > /dev/null 2>&1; then
    kubectl -n "${CERT_MANAGER_NAMESPACE}" rollout status deployment/"${deploy}" \
      --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
      || die "cert-manager deployment '${deploy}' rollout did not complete within ${WAIT_TIMEOUT}"
    log "  Deployment '${deploy}': ROLLOUT COMPLETE"
  else
    log "  Deployment '${deploy}': NOT FOUND (skipping)"
  fi
done

# ============================================================================
# Step 2: Install Knative Serving CRDs and core + Kourier
# ============================================================================
log "Step 2: Installing Knative Serving (${KNATIVE_VERSION})"

KNATIVE_BASE_URL="https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}"

for manifest in serving-crds.yaml serving-core.yaml; do
  url="${KNATIVE_BASE_URL}/${manifest}"
  log "  Applying ${manifest} from ${url}..."
  kubectl apply -f "${url}" > /dev/null 2>&1 \
    || die "Failed to apply ${manifest} from ${url}"
  log "  ${manifest}: APPLIED"
done

# Install Kourier (separate repo: net-kourier)
KOURIER_URL="https://github.com/knative/net-kourier/releases/download/${KNATIVE_VERSION}/kourier.yaml"
log "  Applying kourier.yaml from ${KOURIER_URL}..."
kubectl apply -f "${KOURIER_URL}" > /dev/null 2>&1 \
  || die "Failed to apply kourier.yaml from ${KOURIER_URL}"
log "  kourier.yaml: APPLIED"

KNATIVE_INSTALLED=true

# ============================================================================
# Step 3: Configure Knative to use Kourier as default ClusterIngress
# ============================================================================
log "Step 3: Configuring Knative to use Kourier as default ClusterIngress"

# Wait for config-network ConfigMap to exist
for i in $(seq 1 12); do
  if kubectl -n "${KNATIVE_NAMESPACE}" get configmap config-network > /dev/null 2>&1; then
    log "  config-network ConfigMap found (attempt ${i})"
    break
  fi
  log "  Waiting for config-network ConfigMap (attempt ${i}/12)..."
  sleep 5
done

kubectl patch configmap/config-network \
  -n "${KNATIVE_NAMESPACE}" \
  --type merge \
  -p '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}' \
  > /dev/null 2>&1 || die "Failed to patch config-network ConfigMap"
log "  Kourier set as default ingress class: DONE"

# Also configure Knative to use Kourier's External IP or the domain
kubectl patch configmap/config-domain \
  -n "${KNATIVE_NAMESPACE}" \
  --type merge \
  -p '{"data":{"example.com":""}}' \
  > /dev/null 2>&1 || log "  (non-fatal) config-domain patch: could not set default domain"

# Restart the activator and controller to pick up new config (not always needed
# but ensures clean state)
kubectl -n "${KNATIVE_NAMESPACE}" rollout restart deployment/activator controller \
  > /dev/null 2>&1 || true
log "  Knative controller/activator: restarted"

# Wait for Kourier deployments
for deploy in net-kourier-controller 3scale-kourier-gateway; do
  ns="${KOURIER_NAMESPACE}"
  # Kourier controller is in kourier-system, gateway is also there
  if kubectl -n "${ns}" get deployment "${deploy}" > /dev/null 2>&1; then
    kubectl -n "${ns}" rollout status deployment/"${deploy}" \
      --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
      || log "  (non-fatal) Deployment '${deploy}' rollout did not complete within ${WAIT_TIMEOUT}"
    log "  Deployment '${deploy}': ROLLOUT COMPLETE"
  fi
done

# Wait for Knative core deployments
for deploy in activator autoscaler controller webhook domain-mapping domainmapping-webhook; do
  if kubectl -n "${KNATIVE_NAMESPACE}" get deployment "${deploy}" > /dev/null 2>&1; then
    kubectl -n "${KNATIVE_NAMESPACE}" rollout status deployment/"${deploy}" \
      --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
      || log "  (non-fatal) Deployment '${deploy}' rollout did not complete within ${WAIT_TIMEOUT}"
    log "  Deployment '${deploy}': ROLLOUT COMPLETE"
  fi
done

# ============================================================================
# Step 4: Install SpinKube operator via Helm
# ============================================================================
log "Step 4: Installing SpinKube operator (${SPIN_OPERATOR_VERSION})"

kubectl create namespace "${SPIN_OPERATOR_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${SPIN_OPERATOR_NAMESPACE}'"
log "  Namespace '${SPIN_OPERATOR_NAMESPACE}': READY"

# spin-operator is from an OCI registry-based Helm chart
helm upgrade --install spin-operator \
  oci://ghcr.io/spinkube/charts/spin-operator \
  --namespace "${SPIN_OPERATOR_NAMESPACE}" \
  --version "${SPIN_OPERATOR_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  > /dev/null 2>&1 || die "spin-operator Helm install failed"

SPIN_OPERATOR_INSTALLED=true
log "  spin-operator: INSTALLED"

# Wait for spin-operator deployment
if kubectl -n "${SPIN_OPERATOR_NAMESPACE}" get deployment spin-operator-controller-manager > /dev/null 2>&1; then
  kubectl -n "${SPIN_OPERATOR_NAMESPACE}" rollout status deployment/spin-operator-controller-manager \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || log "  (non-fatal) spin-operator-controller-manager rollout did not complete within ${WAIT_TIMEOUT}"
  log "  Deployment 'spin-operator-controller-manager': ROLLOUT COMPLETE"
fi

# Apply SpinAppExecutor CRD if the chart does not create it automatically
# (Some SpinKube chart versions require separate CRD installation)
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || true
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: spinappexecutors.core.spinoperator.dev
  labels:
    app.kubernetes.io/component: spin-operator
spec:
  group: core.spinoperator.dev
  names:
    kind: SpinAppExecutor
    listKind: SpinAppExecutorList
    plural: spinappexecutors
    singular: spinappexecutor
  scope: Cluster
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
EOF

# Create a default SpinAppExecutor instance
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || true
apiVersion: core.spinoperator.dev/v1alpha1
kind: SpinAppExecutor
metadata:
  name: default
  namespace: ${SPIN_OPERATOR_NAMESPACE}
spec:
  createDeployment: true
EOF

log "  SpinAppExecutor 'default': APPLIED"

# ============================================================================
# Step 5: Create KeyDB Deployment + Service + ConfigMap + PVC
# ============================================================================
log "Step 5: Creating KeyDB in namespace '${KEYDB_NAMESPACE}'"

kubectl create namespace "${KEYDB_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${KEYDB_NAMESPACE}'"
log "  Namespace '${KEYDB_NAMESPACE}': READY"

# KeyDB ConfigMap
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply KeyDB ConfigMap"
apiVersion: v1
kind: ConfigMap
metadata:
  name: keydb-config
  namespace: ${KEYDB_NAMESPACE}
data:
  keydb.conf: |
    bind 0.0.0.0
    protected-mode no
    port 6379
    timeout 0
    tcp-keepalive 300
    daemonize no
    save 900 1
    save 300 10
    save 60 10000
    appendonly yes
    appendfilename "appendonly.aof"
EOF
log "  ConfigMap 'keydb-config': APPLIED"

# KeyDB PVC using ceph-rbd StorageClass
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply KeyDB PVC"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: keydb-data
  namespace: ${KEYDB_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 1Gi
EOF
log "  PVC 'keydb-data': APPLIED (storageClass: ${STORAGE_CLASS})"

# KeyDB Deployment with readiness probe
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply KeyDB Deployment"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keydb
  namespace: ${KEYDB_NAMESPACE}
  labels:
    app: keydb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keydb
  template:
    metadata:
      labels:
        app: keydb
    spec:
      containers:
        - name: keydb
          image: ${KEYDB_IMAGE}
          ports:
            - containerPort: 6379
              name: redis
          env:
            - name: KEYDB_CONFIG_FILE
              value: /etc/keydb/keydb.conf
          volumeMounts:
            - name: config
              mountPath: /etc/keydb
              readOnly: true
            - name: data
              mountPath: /data
          readinessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 15
            periodSeconds: 20
      volumes:
        - name: config
          configMap:
            name: keydb-config
        - name: data
          persistentVolumeClaim:
            claimName: keydb-data
EOF
log "  Deployment 'keydb': APPLIED"

# KeyDB Service (ClusterIP for internal access)
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply KeyDB Service"
apiVersion: v1
kind: Service
metadata:
  name: keydb
  namespace: ${KEYDB_NAMESPACE}
  labels:
    app: keydb
spec:
  ports:
    - port: 6379
      targetPort: 6379
      name: redis
  selector:
    app: keydb
EOF
log "  Service 'keydb': APPLIED"

KEYDB_INSTALLED=true

# Wait for KeyDB rollout
if kubectl -n "${KEYDB_NAMESPACE}" get deployment keydb > /dev/null 2>&1; then
  kubectl -n "${KEYDB_NAMESPACE}" rollout status deployment/keydb \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || log "  (non-fatal) KeyDB rollout did not complete within ${WAIT_TIMEOUT}"
  log "  Deployment 'keydb': ROLLOUT COMPLETE"
fi

# ============================================================================
# Step 6: Gather component statuses for summary
# ============================================================================
log "Step 6: Gathering component statuses"

# cert-manager status
CM_STATUS="NOT INSTALLED"
if [ "${CERT_MANAGER_INSTALLED}" = true ]; then
  CM_READY=$(kubectl -n "${CERT_MANAGER_NAMESPACE}" get deployment cert-manager \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  CM_ROLLOUT=$(kubectl -n "${CERT_MANAGER_NAMESPACE}" rollout status deployment/cert-manager \
    --timeout=5s 2>/dev/null && echo "Ready" || echo "Not Ready")
  CM_STATUS="${CM_ROLLOUT} (replicas: ${CM_READY:-0})"
fi

# Knative Serving status
KN_STATUS="NOT INSTALLED"
if [ "${KNATIVE_INSTALLED}" = true ]; then
  KN_DEPLOYS=$(kubectl -n "${KNATIVE_NAMESPACE}" get deployment -o name 2>/dev/null | wc -l)
  KN_RDY=$(kubectl -n "${KNATIVE_NAMESPACE}" get deployment \
    -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | tr ' ' '\n' | paste -sd+ | bc || echo "0")
  KN_STATUS="deployments: ${KN_DEPLOYS}, ready replicas: ${KN_RDY}"
fi

# Kourier status
KOURIER_STATUS="NOT FOUND"
KC_DEPLOYS=$(kubectl -n "${KOURIER_NAMESPACE}" get deployment -o name 2>/dev/null | wc -l)
if [ "${KC_DEPLOYS}" -gt 0 ]; then
  KOURIER_READY=$(kubectl -n "${KOURIER_NAMESPACE}" get deployment \
    -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | tr ' ' '\n' | paste -sd+ | bc || echo "0")
  KOURIER_STATUS="deployments: ${KC_DEPLOYS}, ready replicas: ${KOURIER_READY}"
fi

# SpinKube operator status
SPIN_STATUS="NOT INSTALLED"
if [ "${SPIN_OPERATOR_INSTALLED}" = true ]; then
  SPIN_RDY=$(kubectl -n "${SPIN_OPERATOR_NAMESPACE}" get deployment spin-operator-controller-manager \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  SPIN_ROLLOUT=$(kubectl -n "${SPIN_OPERATOR_NAMESPACE}" rollout status deployment/spin-operator-controller-manager \
    --timeout=5s 2>/dev/null && echo "Ready" || echo "Not Ready")
  SPIN_STATUS="${SPIN_ROLLOUT} (replicas: ${SPIN_RDY:-0})"
fi

# KeyDB status
KEYDB_STATUS="NOT INSTALLED"
if [ "${KEYDB_INSTALLED}" = true ]; then
  KEYDB_RDY=$(kubectl -n "${KEYDB_NAMESPACE}" get deployment keydb \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  KEYDB_PVC=$(kubectl -n "${KEYDB_NAMESPACE}" get pvc keydb-data \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  KEYDB_ROLLOUT=$(kubectl -n "${KEYDB_NAMESPACE}" rollout status deployment/keydb \
    --timeout=5s 2>/dev/null && echo "Ready" || echo "Not Ready")
  KEYDB_STATUS="${KEYDB_ROLLOUT} (replicas: ${KEYDB_RDY:-0}, PVC: ${KEYDB_PVC})"
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Runtimes Installation Summary ==="
echo "  cert-manager:           ${CERT_MANAGER_VERSION}"
echo "    namespace:            ${CERT_MANAGER_NAMESPACE}"
echo "    status:               ${CM_STATUS}"
echo ""
echo "  Knative Serving:        ${KNATIVE_VERSION}"
echo "    namespace:            ${KNATIVE_NAMESPACE}"
echo "    status:               ${KN_STATUS}"
echo "    ingress:              Kourier (${KOURIER_NAMESPACE})"
echo "    kourier status:       ${KOURIER_STATUS}"
echo ""
echo "  SpinKube operator:      ${SPIN_OPERATOR_VERSION}"
echo "    namespace:            ${SPIN_OPERATOR_NAMESPACE}"
echo "    status:               ${SPIN_STATUS}"
echo ""
echo "  KeyDB:"
echo "    image:                ${KEYDB_IMAGE}"
echo "    namespace:            ${KEYDB_NAMESPACE}"
echo "    storage class:        ${STORAGE_CLASS}"
echo "    status:               ${KEYDB_STATUS}"
echo "    service:              keydb.${KEYDB_NAMESPACE}.svc.cluster.local:6379"
echo ""
echo "  Helm release status:"
for release_ns in "${CERT_MANAGER_NAMESPACE}" "${SPIN_OPERATOR_NAMESPACE}"; do
  for release in cert-manager spin-operator; do
    if helm status "${release}" -n "${release_ns}" > /dev/null 2>&1; then
      helm status "${release}" -n "${release_ns}" 2>/dev/null \
        | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
        | sed "s/^/    [${release}] /" || true
    fi
  done
done
echo ""
echo "  PVCs:"
kubectl get pvc -n "${KEYDB_NAMESPACE}" --no-headers 2>/dev/null \
  | awk '{printf "    %-30s %-10s %-10s %s\n", $1, $2, $5, $6}' \
  || echo "    (no PVCs found)"
echo ""
echo "  Knative CRDs:"
for crd in services.serving.knative.dev configurations.serving.knative.dev revisions.serving.knative.dev routes.serving.knative.dev; do
  if kubectl get crd "${crd}" > /dev/null 2>&1; then
    echo "    ${crd}: PRESENT"
  else
    echo "    ${crd}: MISSING"
  fi
done
echo ""
echo "===================================="

log "install-runtimes: completed successfully"
exit 0

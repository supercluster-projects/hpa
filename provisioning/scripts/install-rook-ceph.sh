#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-rook-ceph.sh — Deploy Rook Ceph operator with CephCluster CR and
#                         ceph-rbd StorageClass
#
# Installs Rook via Helm operator, creates a CephCluster targeting worker
# nodes' /dev/vdb raw disks (one OSD per worker) via deviceFilter, and
# configures a ceph-rbd StorageClass backed by a default.rbd CephBlockPool
# for PersistentVolumeClaim consumption.
#
# Idempotent: safe to re-run on an already-configured cluster.
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-rook-ceph.sh [--kubeconfig <path>] [--rook-version <ver>]
#                               [--ceph-image <image>] [--cluster-name <name>]
#                               [--wait-timeout <duration>] [--pool-cidr <cidr>]
#                               [--worker-count <count>] [--node-prefix <prefix>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env ROOK_VERSION
require_env CEPH_VERSION
require_env DEV_CIDR_BLOCK
require_env DEV_CLUSTER_NAME
require_env DEV_NODE_PREFIX
require_env DEV_WORKER_COUNT

# ---- Internal defaults (script-internal only) -------------------------
CLUSTER_NAME="${DEV_CLUSTER_NAME}"
NODE_PREFIX="${DEV_NODE_PREFIX}"
WORKER_COUNT="${DEV_WORKER_COUNT}"
POOL_CIDR="${DEV_CIDR_BLOCK}"
WAIT_TIMEOUT=600
HELM_RELEASE_NAME="rook-ceph"
HELM_NAMESPACE="rook-ceph"
CEPH_IMAGE="quay.io/ceph/ceph:${CEPH_VERSION}"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";     shift 2 ;;
    --rook-version)   ROOK_VERSION="$2";   shift 2 ;;
    --ceph-image)     CEPH_IMAGE="$2";     shift 2 ;;
    --cluster-name)   CLUSTER_NAME="$2";   shift 2 ;;
    --wait-timeout)   WAIT_TIMEOUT="$2";   shift 2 ;;
    --pool-cidr)      POOL_CIDR="$2";      shift 2 ;;
    --worker-count)   WORKER_COUNT="$2";   shift 2 ;;
    --node-prefix)    NODE_PREFIX="$2";    shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Rook Ceph operator with CephCluster and ceph-rbd StorageClass.

Options:
  --kubeconfig PATH       Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --rook-version VER      Rook operator Helm chart version (default: v1.16.4)
  --ceph-image IMAGE      Ceph container image (default: quay.io/ceph/ceph:v20.2.1)
  --cluster-name NAME     Cluster name for CephCluster CR (default: hpa-dev)
  --wait-timeout DUR      Timeout for Helm install and cluster readiness (default: 10m)
  --pool-cidr CIDR        Ceph public network CIDR (set via DEV_CIDR_BLOCK in .env)
  --worker-count COUNT    Number of worker nodes expected (default: 3)
  --node-prefix PREFIX    Hostname prefix for worker nodes (default: hpa-node)
  --help, -h              Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-rook-ceph: starting"
log "  kubeconfig:     ${KUBECONFIG}"
log "  rook-version:   ${ROOK_VERSION}"
log "  ceph-image:     ${CEPH_IMAGE}"
log "  cluster-name:   ${CLUSTER_NAME}"
log "  wait-timeout:   ${WAIT_TIMEOUT}"
log "  pool-cidr:      ${POOL_CIDR}"
log "  worker-count:   ${WORKER_COUNT}"
log "  node-prefix:    ${NODE_PREFIX}"

command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Helper: build worker node names --------------------------------------
# Generates the list of worker hostnames from prefix and count.
# e.g. NODE_PREFIX=hpa-node WORKER_COUNT=3 produces:
#       hpa-node-worker-0 hpa-node-worker-1 hpa-node-worker-2
build_worker_names() {
  local prefix="$1"
  local count="$2"
  local i
  for i in $(seq 0 $((count - 1))); do
    echo "${prefix}-worker-${i}"
  done
}
read -r -a WORKER_NAMES <<< "$(build_worker_names "${NODE_PREFIX}" "${WORKER_COUNT}")"
log "  worker targets: ${WORKER_NAMES[*]}"

# ============================================================================
# Step 1: Add/update Rook Helm repo
# ============================================================================
log "Step 1: Adding/updating Rook Helm repo (${ROOK_HELM_REPO})"
helm repo add rook-release "${ROOK_HELM_REPO}" --force-update > /dev/null 2>&1 \
  || die "Failed to add Rook Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Rook Helm repo: READY"

# ============================================================================
# Step 2: Install/upgrade rook-ceph-operator via Helm
# ============================================================================
log "Step 2: Installing/upgrading rook-ceph-operator via Helm"
helm upgrade --install "${HELM_RELEASE_NAME}" rook-release/rook-ceph \
  --namespace "${HELM_NAMESPACE}" \
  --create-namespace \
  --version "${ROOK_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set "csi.enableRbdDriver=true" \
  --set "csi.enableCephfsDriver=false" \
  --set "csi.enableNfsDriver=false" \
  --set "enableDiscoveryDaemon=false" \
  > /dev/null 2>&1 || die "Helm install/upgrade failed"
log "  Helm release '${HELM_RELEASE_NAME}': INSTALLED/UPGRADED"

# ---- Brief pause for operator CRD registration ----------------------------
log "  Waiting for CRDs to register..."
sleep 5

# Verify the operator pod is running
OPERATOR_POD=""
for i in 1 2 3 4 5; do
  OPERATOR_POD=$(kubectl -n "${HELM_NAMESPACE}" get pod -l app=rook-ceph-operator -o name 2>/dev/null || true)
  if [ -n "${OPERATOR_POD}" ]; then
    break
  fi
  log "  Waiting for operator pod to appear (attempt ${i}/5)..."
  sleep 3
done
[ -n "${OPERATOR_POD}" ] || die "rook-ceph-operator pod did not appear within the retry window"

log "  Operator pod: ${OPERATOR_POD}"

# ============================================================================
# Step 3: Apply CephCluster CR
# ============================================================================
log "Step 3: Applying CephCluster CR '${CLUSTER_NAME}'"

# Build the storage.nodes YAML list from worker names
STORAGE_NODES=""
for w in "${WORKER_NAMES[@]}"; do
  STORAGE_NODES="${STORAGE_NODES}
      - name: ${w}
        deviceFilter: \"^vdb$\""
done

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply CephCluster CR"
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${HELM_NAMESPACE}
spec:
  cephVersion:
    image: ${CEPH_IMAGE}
    allowUnsupported: false
  dataDirHostPath: /var/lib/rook
  mon:
    count: 3
    allowMultiplePerNode: false
  dashboard:
    enabled: true
    ssl: true
  network:
    connections:
      public:
        - "${POOL_CIDR}"
  storage:
    useAllNodes: false
    useAllDevices: false
    config:
      crushRoot: default
    nodes:${STORAGE_NODES}
EOF
log "  CephCluster '${CLUSTER_NAME}': APPLIED"

# ============================================================================
# Step 4: Apply CephBlockPool 'default.rbd' with replication 1
# ============================================================================
log "Step 4: Applying CephBlockPool 'default.rbd' (replication: 1)"
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply CephBlockPool"
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: default.rbd
  namespace: ${HELM_NAMESPACE}
spec:
  replicated:
    size: 1
EOF
log "  CephBlockPool 'default.rbd': APPLIED"

# ============================================================================
# Step 5: Apply ceph-rbd StorageClass
# ============================================================================
log "Step 5: Applying StorageClass 'ceph-rbd'"
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply StorageClass"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
provisioner: ${HELM_NAMESPACE}.rbd.csi.ceph.com
parameters:
  clusterID: ${HELM_NAMESPACE}
  pool: default.rbd
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${HELM_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${HELM_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${HELM_NAMESPACE}
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF
log "  StorageClass 'ceph-rbd': APPLIED"

# ============================================================================
# Step 6: Wait for CephCluster to reach Ready phase
# ============================================================================
log "Step 6: Waiting for CephCluster to reach 'Ready' phase (timeout: ${WAIT_TIMEOUT})"

# Parse wait-timeout into seconds for our loop
TIMEOUT_SECONDS=600
case "${WAIT_TIMEOUT}" in
  *m) TIMEOUT_SECONDS=$(( ${WAIT_TIMEOUT%m} * 60 )) ;;
  *s) TIMEOUT_SECONDS="${WAIT_TIMEOUT%s}" ;;
  *h) TIMEOUT_SECONDS=$(( ${WAIT_TIMEOUT%h} * 3600 )) ;;
esac

ELAPSED=0
INTERVAL=15
CEPH_READY=false
PHASE_HISTORY=""

while [ "${ELAPSED}" -lt "${TIMEOUT_SECONDS}" ]; do
  CLUSTER_JSON=$(kubectl -n "${HELM_NAMESPACE}" get cephcluster "${CLUSTER_NAME}" -o json 2>/dev/null || true)

  if [ -z "${CLUSTER_JSON}" ]; then
    log "  CephCluster not yet found (${ELAPSED}s elapsed)..."
  else
    PHASE=$(echo "${CLUSTER_JSON}" | grep -o '"phase":"[^"]*"' | head -1 || echo '"phase":"unknown"')
    HEALTH=$(echo "${CLUSTER_JSON}" | grep -o '"health":"[^"]*"' | head -1 || echo '"health":"unknown"')

    # Track phase transitions
    CURRENT_PHASE="${PHASE}"
    if ! echo "${PHASE_HISTORY}" | grep -q "${CURRENT_PHASE}"; then
      PHASE_HISTORY="${PHASE_HISTORY} -> ${CURRENT_PHASE}"
    fi

    if echo "${PHASE}" | grep -q '"Ready"'; then
      CEPH_READY=true
      log "  CephCluster phase: Ready (${HEALTH}) — AFTER ${ELAPSED}s"
      break
    else
      log "  CephCluster phase: ${PHASE} ${HEALTH} (${ELAPSED}s elapsed)..."
    fi
  fi

  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ "${CEPH_READY}" != true ]; then
  die "CephCluster did not reach Ready phase within ${WAIT_TIMEOUT} (phase history:${PHASE_HISTORY})"
fi

# ---- Conditional: check CephCluster overall health ---------------------------
log "  Performing final CephCluster health check"
HEALTH_CHECK=$(kubectl -n "${HELM_NAMESPACE}" get cephcluster "${CLUSTER_NAME}" -o jsonpath='{.status.ceph.health}' 2>/dev/null || true)
if [ -n "${HEALTH_CHECK}" ]; then
  log "  Ceph health: ${HEALTH_CHECK}"
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Rook Ceph Installation Summary ==="
echo "  Rook version:         ${ROOK_VERSION}"
echo "  Ceph image:           ${CEPH_IMAGE}"
echo "  Helm release:         ${HELM_RELEASE_NAME} (namespace: ${HELM_NAMESPACE})"
echo "  Cluster CR name:      ${CLUSTER_NAME}"
echo "  Worker count:         ${WORKER_COUNT}"
echo "  Worker targets:       ${WORKER_NAMES[*]}"
echo "  Target device:        /dev/vdb (deviceFilter: ^vdb$)"
echo "  CephBlockPool:        default.rbd (replicated: 1)"
echo "  StorageClass:         ceph-rbd"
echo ""
echo "  Helm release status:"
helm status "${HELM_RELEASE_NAME}" -n "${HELM_NAMESPACE}" 2>/dev/null \
  | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
  | sed 's/^/    /' || echo "    (unable to query)"
echo ""
echo "  Operator pod:"
kubectl -n "${HELM_NAMESPACE}" get pod -l app=rook-ceph-operator --no-headers 2>/dev/null \
  | awk '{print "    " $1 " - " $3 " (" $2 ")"}' || echo "    (not found)"
echo ""
echo "  CephCluster:"
kubectl -n "${HELM_NAMESPACE}" get cephcluster "${CLUSTER_NAME}" -o wide --no-headers 2>/dev/null \
  | awk '{print "    " $1 " - phase: " $2 " - health: " $3}' || echo "    (not found)"
echo ""
echo "  CephBlockPools:"
kubectl -n "${HELM_NAMESPACE}" get cephblockpool --no-headers 2>/dev/null \
  | awk '{print "    " $1}' || echo "    (none)"
echo ""
echo "  StorageClasses:"
kubectl get sc ceph-rbd --no-headers 2>/dev/null \
  | awk '{print "    " $1 " (provisioner: " $2 ")"}' || echo "    (not found)"
echo ""
echo "  Phase history:${PHASE_HISTORY}"
echo "========================================"

log "install-rook-ceph: completed successfully"
exit 0

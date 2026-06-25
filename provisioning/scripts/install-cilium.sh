#!/usr/bin/env bash
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"
# install-cilium.sh — Deploy Cilium CNI on a Talos cluster with L2 LB config
#
# Installs Cilium via Helm with L2 announcement and LoadBalancer IP pool
# configuration. Creates CiliumLoadBalancerIPPool and
# CiliumL2AnnouncementPolicy CRDs for LoadBalancer service support.
#
# Idempotent: safe to re-run on an already-configured cluster.
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-cilium.sh [--kubeconfig <path>] [--cilium-version <ver>]
#                            [--lb-pool-cidr <cidr>] [--cluster-name <name>]
#                            [--wait-timeout <duration>]
# ---------------------------------------------------------------------------

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env CILIUM_VERSION
require_env DEV_LB_POOL_CIDR
require_env DEV_CLUSTER_NAME

# ---- Internal defaults (script-internal only) -------------------------
CLUSTER_NAME="${DEV_CLUSTER_NAME}"
LB_POOL_CIDR="${DEV_LB_POOL_CIDR}"
WAIT_TIMEOUT=300
HELM_RELEASE_NAME="cilium"
HELM_NAMESPACE="kube-system"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";     shift 2 ;;
    --cilium-version) CILIUM_VERSION="$2"; shift 2 ;;
    --lb-pool-cidr)   LB_POOL_CIDR="$2";   shift 2 ;;
    --cluster-name)   CLUSTER_NAME="$2";   shift 2 ;;
    --wait-timeout)   WAIT_TIMEOUT="$2";   shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Cilium CNI with L2 LoadBalancer configuration on a Talos cluster.

Options:
  --kubeconfig PATH       Path to kubeconfig (default: ../tofu-libvirt-dev/kubeconfig)
  --cilium-version VER    Cilium Helm chart version (default: 1.16.5)
  --lb-pool-cidr CIDR     LoadBalancer IP pool CIDR (set via DEV_LB_POOL_CIDR in .env)
  --cluster-name NAME     Cluster name for Helm values (default: hpa-dev)
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
log "install-cilium: starting"
log "  kubeconfig:     ${KUBECONFIG}"
log "  cilium-version: ${CILIUM_VERSION}"
log "  lb-pool-cidr:   ${LB_POOL_CIDR}"
log "  (DEV_LB_POOL_CIDR env: ${DEV_LB_POOL_CIDR:-not set})"
log "  cluster-name:   ${CLUSTER_NAME}"
log "  wait-timeout:   ${WAIT_TIMEOUT}"

command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Step 1: Add/update Cilium Helm repo ----------------------------------
log "Step 1: Adding/updating Cilium Helm repo"
helm repo add cilium https://helm.cilium.io/ --force-update > /dev/null 2>&1 \
  || die "Failed to add Cilium Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Cilium Helm repo: READY"

# ---- Step 2: Install/upgrade Cilium via Helm ------------------------------
log "Step 2: Installing/upgrading Cilium via Helm (version ${CILIUM_VERSION})"
helm upgrade --install "${HELM_RELEASE_NAME}" cilium/cilium \
  --namespace "${HELM_NAMESPACE}" \
  --version "${CILIUM_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set "cluster.name=${CLUSTER_NAME}" \
  --set "kubeProxyReplacement=disabled" \
  --set "l2announcements.enabled=true" \
  --set "externalIPs.enabled=true" \
  --set "ipam.mode=cluster-pool" \
  --set "ipam.operator.clusterPoolIPv4PodCIDR=10.0.0.0/16" \
  --set "ipam.operator.clusterPoolIPv4MaskSize=24" \
  > /dev/null 2>&1 || die "Helm install/upgrade failed"
log "  Helm release '${HELM_RELEASE_NAME}': INSTALLED/UPGRADED"

# ---- Step 3: Wait for Cilium DaemonSet rollout ----------------------------
log "Step 3: Waiting for Cilium DaemonSet rollout"
kubectl -n "${HELM_NAMESPACE}" rollout status ds/cilium --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
  || die "Cilium DaemonSet rollout did not complete within ${WAIT_TIMEOUT}"
log "  Cilium DaemonSet rollout: COMPLETE"

# ---- Step 4: Apply CiliumLoadBalancerIPPool -------------------------------
log "Step 4: Applying CiliumLoadBalancerIPPool 'hpa-dev-lb-pool' (${LB_POOL_CIDR})"
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply CiliumLoadBalancerIPPool"
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: hpa-dev-lb-pool
spec:
  blocks:
    - cidr: "${LB_POOL_CIDR}"
EOF
log "  CiliumLoadBalancerIPPool 'hpa-dev-lb-pool': APPLIED"

# ---- Step 5: Apply CiliumL2AnnouncementPolicy ----------------------------
log "Step 5: Applying CiliumL2AnnouncementPolicy 'hpa-dev-l2-policy'"
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply CiliumL2AnnouncementPolicy"
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: hpa-dev-l2-policy
spec:
  interfaces:
    - bond0
  externalIPs: true
  loadBalancerIPs: true
EOF
log "  CiliumL2AnnouncementPolicy 'hpa-dev-l2-policy': APPLIED"

# ---- Step 6: Verify LB pool is recognized ---------------------------------
log "Step 6: Verifying CiliumLoadBalancerIPPool is recognized"
POOL_STATUS=$(
  kubectl get ciliumloadbalancerippool hpa-dev-lb-pool \
    -o jsonpath='{.status.conditions}' 2>/dev/null || true
)
if [ -n "${POOL_STATUS}" ]; then
  log "  LB pool conditions: ${POOL_STATUS}"
else
  log "  LB pool created (conditions not yet available — Cilium agent may still be initializing)"
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Cilium Installation Summary ==="
echo "  Cilium version:       ${CILIUM_VERSION}"
echo "  Helm release:         ${HELM_RELEASE_NAME} (namespace: ${HELM_NAMESPACE})"
echo "  LB pool CIDR:         ${LB_POOL_CIDR}"
echo "  LB pool name:         hpa-dev-lb-pool"
echo "  L2 policy name:       hpa-dev-l2-policy"
echo "  Cluster:              ${CLUSTER_NAME}"
echo ""
echo "  Helm release status:"
helm status "${HELM_RELEASE_NAME}" -n "${HELM_NAMESPACE}" 2>/dev/null \
  | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
  | sed 's/^/    /' || echo "    (unable to query)"
echo ""
echo "  CRD state:"
for crd in ciliumloadbalancerippools ciliuml2announcementpolicies; do
  if kubectl get crd "${crd}.cilium.io" > /dev/null 2>&1; then
    COUNT=$(kubectl get "${crd}.cilium.io" --no-headers 2>/dev/null | wc -l)
    echo "    ${crd}: ${COUNT} instance(s)"
  else
    echo "    ${crd}: NOT FOUND"
  fi
done
echo "==================================="

log "install-cilium: completed successfully"
exit 0

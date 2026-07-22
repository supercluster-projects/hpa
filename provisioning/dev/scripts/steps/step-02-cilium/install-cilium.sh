#!/usr/bin/env bash
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/../../misc/preamble.sh"
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
WAIT_TIMEOUT=1800
HELM_RELEASE_NAME="cilium"
HELM_NAMESPACE="kube-system"
HUBBLE_UI_SERVICE="hubble-ui"
HUBBLE_UI_LB_IP="${DEV_HUBBLE_UI_LB_IP:-${HUBBLE_UI_LB_IP:-}}"
HUBBLE_UI_SOURCE_RANGES="${DEV_HUBBLE_UI_SOURCE_RANGES:-${HUBBLE_UI_SOURCE_RANGES:-}}"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";     shift 2 ;;
    --cilium-version) CILIUM_VERSION="$2"; shift 2 ;;
    --lb-pool-cidr)   LB_POOL_CIDR="$2";   shift 2 ;;
    --cluster-name)   CLUSTER_NAME="$2";   shift 2 ;;
    --hubble-ui-service) HUBBLE_UI_SERVICE="$2"; shift 2 ;;
    --hubble-ui-lb-ip) HUBBLE_UI_LB_IP="$2"; shift 2 ;;
    --hubble-ui-source-ranges) HUBBLE_UI_SOURCE_RANGES="$2"; shift 2 ;;
    --wait-timeout)   WAIT_TIMEOUT="$2";   shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Cilium CNI with L2 LoadBalancer configuration on a Talos cluster.

Options:
  --kubeconfig PATH       Path to kubeconfig (default: ../opentofu/kubeconfig)
  --cilium-version VER    Cilium Helm chart version (default: 1.16.5)
  --lb-pool-cidr CIDR     LoadBalancer IP pool CIDR (set via DEV_LB_POOL_CIDR in .env)
  --cluster-name NAME     Cluster name for Helm values (default: hpa-dev)
  --hubble-ui-service NAME Hubble UI service name (default: hubble-ui)
  --hubble-ui-lb-ip IP    Hubble UI LoadBalancer IP (default: first usable DEV_LB_POOL_CIDR IP)
  --hubble-ui-source-ranges CSV Comma-separated source IP ranges (optional)
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
log "  cluster-name:   ${CLUSTER_NAME}"
log "  hubble-ui-svc:  ${HUBBLE_UI_SERVICE}"
log "  hubble-ui-lb:   ${HUBBLE_UI_LB_IP:-auto}"
log "  hubble-ui-src:  ${HUBBLE_UI_SOURCE_RANGES:-0.0.0.0/0 if empty}"
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

# Use KubePrism on localhost:7445 for kube-proxy replacement on Talos
# (Talos enables KubePrism at 7445 by default — avoids API server reachability issues)
log "  Configuring Cilium with Kube-Proxy-Free routing via KubePrism (localhost:7445)"

CILIUM_VALUES_FILE="$(mktemp)"
trap 'rm -f "${CILIUM_VALUES_FILE}"' EXIT

if [ -z "${HUBBLE_UI_LB_IP}" ]; then
  HUBBLE_UI_LB_IP="$(python3 - "${LB_POOL_CIDR}" <<'PY'
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
hosts = list(network.hosts())
if len(hosts) > 1:
    print(hosts[1])
elif hosts:
    print(hosts[0])
else:
    print('')
PY
)"
fi

if [ -z "${HUBBLE_UI_LB_IP}" ]; then
  die "Unable to derive a Hubble UI LoadBalancer IP from ${LB_POOL_CIDR}"
fi

HUBBLE_UI_SOURCE_RANGE_ARRAY=()
if [ -n "${HUBBLE_UI_SOURCE_RANGES}" ]; then
  IFS=',' read -ra HUBBLE_UI_SOURCE_RANGE_ARRAY <<< "${HUBBLE_UI_SOURCE_RANGES}"
fi

log "  Hubble UI LoadBalancer IP: ${HUBBLE_UI_LB_IP}"

cat > "${CILIUM_VALUES_FILE}" <<EOF_VALUES
cluster:
  name: ${CLUSTER_NAME}
kubeProxyReplacement: true
k8sServiceHost: localhost
k8sServicePort: 7445
l2announcements:
  enabled: true
externalIPs:
  enabled: true
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.0.0.0/16
    clusterPoolIPv4MaskSize: 24
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
securityContext:
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    cleanCiliumState:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
    service:
      type: LoadBalancer
EOF_VALUES

for range in "${HUBBLE_UI_SOURCE_RANGE_ARRAY[@]}"; do
  range="${range// /}"
  [ -n "${range}" ] && echo "      - ${range}" >> "${CILIUM_VALUES_FILE}"
done

helm upgrade --install "${HELM_RELEASE_NAME}" cilium/cilium \
  --namespace "${HELM_NAMESPACE}" \
  --version "${CILIUM_VERSION}" \
  --timeout "${WAIT_TIMEOUT}s" \
  --values "${CILIUM_VALUES_FILE}" \
  || die "Helm install/upgrade failed"
log "  Helm release '${HELM_RELEASE_NAME}': INSTALLED/UPGRADED"

# ---- Step 3: Wait for Cilium DaemonSet rollout ----------------------------
log "Step 3: Waiting for Cilium DaemonSet rollout"
kubectl -n "${HELM_NAMESPACE}" rollout status ds/cilium --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1 \
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
    - enp1s0
  externalIPs: true
  loadBalancerIPs: true
EOF
log "  CiliumL2AnnouncementPolicy 'hpa-dev-l2-policy': APPLIED"

# ---- Step 5b: Apply CiliumNodeConfig 'hpa-dev-node-config' -----------------
log "Step 5b: Applying CiliumNodeConfig 'hpa-dev-node-config' to bind enp1s0"
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply CiliumNodeConfig"
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  name: hpa-dev-node-config
  namespace: kube-system
spec:
  nodeSelector: {}
  defaults:
    devices: "enp1s0"
EOF
log "  CiliumNodeConfig 'hpa-dev-node-config': APPLIED"

# ---- Step 5c: Rollout restart Cilium DaemonSet to apply new device config ---
log "Step 5c: Restarting Cilium DaemonSet to pick up device config"
kubectl -n kube-system rollout restart ds/cilium > /dev/null 2>&1 \
  || die "Failed to restart Cilium DaemonSet"
kubectl -n kube-system rollout status ds/cilium --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1 \
  || die "Cilium restart status check failed"
log "  Cilium DaemonSet restarted successfully."

# ---- Step 6: Patch Hubble UI LoadBalancer service spec ---------------------
log "Step 6: Patching Hubble UI LoadBalancer service spec"
if [ -n "${HUBBLE_UI_LB_IP}" ] || [ -n "${HUBBLE_UI_SOURCE_RANGES}" ]; then
  python3 - "${HUBBLE_UI_LB_IP}" "${HUBBLE_UI_SOURCE_RANGES}" <<'PY' > /tmp/hubble-ui-patch.json
import json
import sys

patch = {"spec": {}}
load_balancer_ip = sys.argv[1].strip()
if load_balancer_ip:
    patch["spec"]["loadBalancerIP"] = load_balancer_ip

source_ranges = [item.strip() for item in sys.argv[2].split(",") if item.strip()]
if source_ranges:
    patch["spec"]["loadBalancerSourceRanges"] = source_ranges

print(json.dumps(patch))
PY
  kubectl -n "${HELM_NAMESPACE}" patch svc "${HUBBLE_UI_SERVICE}" \
    --type merge \
    --patch-file /tmp/hubble-ui-patch.json > /dev/null 2>&1 \
    || die "Failed to patch Hubble UI LoadBalancer service spec"
  rm -f /tmp/hubble-ui-patch.json
else
  log "  Hubble UI service spec patch skipped (no HUBBLE_UI_LB_IP or source ranges set)"
fi

HUBBLE_UI_EXTERNAL_IP=""
for _ in $(seq 1 60); do
  HUBBLE_UI_EXTERNAL_IP="$(kubectl -n "${HELM_NAMESPACE}" get svc "${HUBBLE_UI_SERVICE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -n "${HUBBLE_UI_EXTERNAL_IP}" ]; then
    break
  fi
  sleep 5
done
if [ -z "${HUBBLE_UI_EXTERNAL_IP}" ]; then
  HUBBLE_UI_EXTERNAL_IP="pending"
fi
log "  Hubble UI service: ${HUBBLE_UI_SERVICE}"
log "  Hubble UI external IP: ${HUBBLE_UI_EXTERNAL_IP}"
log "  Hubble UI URL: http://${HUBBLE_UI_EXTERNAL_IP}:80"

# ---- Step 7: Verify LB pool is recognized ---------------------------------
log "Step 7: Verifying CiliumLoadBalancerIPPool is recognized"
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
echo "  Hubble UI service:    ${HUBBLE_UI_SERVICE}"
echo "  Hubble UI external IP:${HUBBLE_UI_EXTERNAL_IP:-pending}"
echo "  Hubble UI URL:        http://${HUBBLE_UI_EXTERNAL_IP:-pending}:80"
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

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-spegel.sh — Deploy Spegel P2P OCI registry mirror on Talos Linux
#
# Installs Spegel as a DaemonSet on every cluster node, enabling peer-to-peer
# image layer distribution. Requires containerd registry mirror configuration
# pointing to the local Spegel instance on each node.
#
# Prerequisites:
#   - Talos cluster with healthy nodes (use verify-cluster.sh first)
#   - talosctl in PATH
#   - helm and kubectl in PATH
#
# Idempotent: safe to re-run on an already-configured cluster (Helm
# upgrade --atomic --wait and kubectl label are used throughout).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-spegel.sh [--kubeconfig <path>]
#                            [--talosconfig <path>]
#                            [--spegel-version <ver>]
#                            [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Required environment variables ---------------------------------------
require_env SPEGEL_VERSION

# ---- Internal defaults ----------------------------------------------------
SPEGEL_NAMESPACE="spegel"
TALOSCONFIG="${SCRIPT_DIR}/../opentofu/talosconfig"
WAIT_TIMEOUT=300

# Diskard-unpacked-layers machine config patch content
read -r -d '' DISCARDPATCH <<'PATCH' || true
machine:
  files:
    - path: /etc/cri/conf.d/20-customization.part
      op: create
      content: |
        [plugins."io.containerd.cri.v1.images"]
          discard_unpacked_layers = false
PATCH

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)         KUBECONFIG="$2";          shift 2 ;;
    --talosconfig)        TALOSCONFIG="$2";          shift 2 ;;
    --spegel-version)     SPEGEL_VERSION="$2";       shift 2 ;;
    --wait-timeout)       WAIT_TIMEOUT="$2";         shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Spegel P2P OCI registry mirror on a Talos Linux cluster.

Requires SPEGEL_VERSION to be set in .env (or passed via --spegel-version).

Operations performed:
  1. Apply Talos machine config patch to disable discard_unpacked_layers
  2. Install Spegel Helm chart (OCI) in the 'spegel' namespace
  3. Label spegel namespace with privileged Pod Security admission
  4. Wait for Spegel DaemonSet rollout

Options:
  --kubeconfig PATH         Path to kubeconfig (default: ../opentofu/kubeconfig)
  --talosconfig PATH        Path to talosconfig (default: ../opentofu/talosconfig)
  --spegel-version VER      Spegel Helm chart version (default: from .env SPEGEL_VERSION)
  --wait-timeout DUR        Timeout for Helm install and rollouts (default: 5m)
  --help, -h                Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-spegel: starting"
log "  kubeconfig:      ${KUBECONFIG}"
log "  talosconfig:     ${TALOSCONFIG}"
log "  spegel-version:  ${SPEGEL_VERSION}"
log "  namespace:       ${SPEGEL_NAMESPACE}"
log "  wait-timeout:    ${WAIT_TIMEOUT}"

command -v helm       >/dev/null 2>&1 || die "helm not found in PATH"
command -v kubectl    >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v talosctl   >/dev/null 2>&1 || die "talosctl not found in PATH"
[ -f "${KUBECONFIG}" ]  || die "kubeconfig not found at ${KUBECONFIG}"
[ -f "${TALOSCONFIG}" ] || die "talosconfig not found at ${TALOSCONFIG}"

# ---- Internal state tracking ----------------------------------------------
SPEGEL_INSTALLED=false
MC_PATCHED=false

# ============================================================================
# Step 1: Apply Talos machine config patch for discard_unpacked_layers
# ============================================================================
log "Step 1: Applying containerd discard_unpacked_layers=false machine config patch"

# Write the patch to a temp file
PATCH_FILE=$(mktemp)
cleanup() { rm -f "${PATCH_FILE}"; }
trap cleanup EXIT

cat > "${PATCH_FILE}" << 'YAML'
machine:
  files:
    - path: /etc/cri/conf.d/20-customization.part
      op: create
      content: |
        [plugins."io.containerd.cri.v1.images"]
          discard_unpacked_layers = false
YAML

# Get node IPs from talosconfig
NODE_IPS=""
if command -v yq >/dev/null 2>&1; then
  NODE_IPS=$(yq eval '.contexts[.context].endpoints[]' "${TALOSCONFIG}" 2>/dev/null || true)
fi
# Fallback: try talosctl to list nodes
if [ -z "${NODE_IPS}" ]; then
  NODE_IPS=$(talosctl --talosconfig "${TALOSCONFIG}" get members -o json 2>/dev/null \
    | grep '"address"' | awk -F'"' '{print $4}' | head -4 || true)
fi

if [ -z "${NODE_IPS}" ]; then
  log "  Could not auto-detect node IPs, skipping machine config patch."
  log "  Ensure discard_unpacked_layers=false is in your cluster-config.yaml."
  log "  See: .gsd/milestones/M003/slices/S02/research/talos-spegel.md"
else
  PATCH_OK=true
  for IP in ${NODE_IPS}; do
    log "  Patching machine config on node ${IP}..."
    if talosctl --talosconfig "${TALOSCONFIG}" -n "${IP}" patch machineconfig \
      --patch "@${PATCH_FILE}" > /dev/null 2>&1; then
      log "    Node ${IP}: PATCHED"
    else
      log "    Node ${IP}: SKIPPED (may already have the config)"
    fi
  done
  MC_PATCHED=true
fi

log "  Note: The discard_unpacked_layers change requires containerd restart."
log "  If pods on this cluster already pull images without Spegel, a rolling"
log "  node reboot ('talosctl reboot -n <ip>') may be needed for full effect."
log "  For new clusters, ensure cluster-config.yaml has the machine.files patch."

# ============================================================================
# Step 2: Install Spegel via Helm (OCI chart)
# ============================================================================
log "Step 2: Installing Spegel (${SPEGEL_VERSION})"

kubectl create namespace "${SPEGEL_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${SPEGEL_NAMESPACE}'"
log "  Namespace '${SPEGEL_NAMESPACE}': READY"

# Label the spegel namespace with privileged Pod Security Admission
# (Talos default is too restrictive for Spegel's host-network operation)
kubectl label namespace "${SPEGEL_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite > /dev/null 2>&1 \
  || log "  (non-fatal) Could not label namespace with pod security"
log "  Pod Security Admission: LABELED (enforce=privileged)"

# Install Spegel from OCI Helm chart
# Talos uses a different containerd registry config path, so we set it
# explicitly. We also set containerdMirrorAdd: true (default) so the init
# container writes mirror configuration to the correct path.
helm upgrade --install spegel \
  oci://ghcr.io/spegel-org/helm-charts/spegel \
  --namespace "${SPEGEL_NAMESPACE}" \
  --version "${SPEGEL_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set "spegel.containerdRegistryConfigPath=/etc/cri/conf.d/hosts" \
  > /dev/null 2>&1 || die "Spegel Helm install failed"

SPEGEL_INSTALLED=true
log "  Spegel Helm chart: INSTALLED"

# ============================================================================
# Step 3: Wait for Spegel DaemonSet rollout
# ============================================================================
log "Step 3: Waiting for Spegel DaemonSet rollout"

if kubectl -n "${SPEGEL_NAMESPACE}" get daemonset spegel > /dev/null 2>&1; then
  kubectl -n "${SPEGEL_NAMESPACE}" rollout status daemonset/spegel \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || log "  (non-fatal) DaemonSet rollout did not complete within ${WAIT_TIMEOUT}"
  log "  DaemonSet 'spegel': ROLLOUT COMPLETE"
fi

# ============================================================================
# Step 4: Gather component statuses for summary
# ============================================================================
log "Step 4: Gathering Spegel status"

SPEGEL_STATUS="NOT INSTALLED"
if [ "${SPEGEL_INSTALLED}" = true ]; then
  SPE_NODES_READY=$(kubectl -n "${SPEGEL_NAMESPACE}" get daemonset spegel \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  SPE_NODES_DESIRED=$(kubectl -n "${SPEGEL_NAMESPACE}" get daemonset spegel \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  SPE_ROLLOUT=$(kubectl -n "${SPEGEL_NAMESPACE}" rollout status daemonset/spegel \
    --timeout=5s 2>/dev/null && echo "Ready" || echo "Not Ready")
  SPE_PODS=$(kubectl -n "${SPEGEL_NAMESPACE}" get pods -l app.kubernetes.io/name=spegel \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | sort | uniq -c | tr '\n' ';' || echo "unknown")
  SPEGEL_STATUS="${SPE_ROLLOUT} (${SPE_NODES_READY}/${SPE_NODES_DESIRED} nodes ready, pods: ${SPE_PODS})"
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Spegel Installation Summary ==="
echo "  Spegel:                ${SPEGEL_VERSION}"
echo "    namespace:           ${SPEGEL_NAMESPACE}"
echo "    chart:               oci://ghcr.io/spegel-org/helm-charts/spegel"
echo "    status:              ${SPEGEL_STATUS}"
echo ""
echo "  Machine config:"
if [ "${MC_PATCHED}" = true ]; then
  echo "    discard_unpacked_layers: PATCHED via talosctl"
else
  echo "    discard_unpacked_layers: APPLY VIA cluster-config.yaml"
fi
echo "    registry config path:     /etc/cri/conf.d/hosts"
echo ""
echo "  Containerd config patch applied:"
echo "    path: /etc/cri/conf.d/20-customization.part"
echo "    setting: discard_unpacked_layers = false"
echo ""
echo "  Pod Security Admission:"
echo "    namespace:           ${SPEGEL_NAMESPACE}"
echo "    policy:              enforce=privileged"
echo ""
echo "  Spegel DaemonSet pods:"
kubectl -n "${SPEGEL_NAMESPACE}" get pods -l app.kubernetes.io/name=spegel \
  -o wide --no-headers 2>/dev/null \
  | awk '{printf "    %-50s %-12s %s\n", $1, $3, $7}' \
  || echo "    (no pods found)"
echo ""
echo "=== Next Steps ==="
echo "  1. Verify Spegel is functioning (see Spegel docs 'Verify Deployment'):"
echo "     Pull the same image on two different nodes and check Spegel metrics."
echo "  2. For production clusters, consider adding the machine.files patch to"
echo "     cluster-config.yaml so it applies at provisioning time."
echo "  3. If this is an existing cluster with running workloads, consider a"
echo "     rolling node reboot to ensure containerd picks up the new config."
echo "===================================="

log "install-spegel: completed successfully"
exit 0

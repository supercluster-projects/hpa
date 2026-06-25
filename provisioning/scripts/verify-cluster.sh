#!/usr/bin/env bash
# verify-cluster.sh — Talos cluster health verification
#
# Runs talosctl health check and kubectl node inspection.
# Exits non-zero if fewer than 4 nodes are Ready or if health check fails.
#
# Usage: ./verify-cluster.sh [--talosconfig <path>] [--kubeconfig <path>]
#   Defaults: --talosconfig ./talosconfig --kubeconfig ./kubeconfig
#
# The script checks for required tools, confirms the cluster is healthy
# via talosctl, then inspects Kubernetes node status. All logging goes
# to stderr; the final node summary table goes to stdout.

set -euo pipefail

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOSCONFIG="${SCRIPT_DIR}/../tofu-libvirt-dev/talosconfig"
KUBECONFIG="${SCRIPT_DIR}/../tofu-libvirt-dev/kubeconfig"
EXPECTED_NODES=4

# --- Helpers ---
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err()  { log "ERROR: $*"; }
die()  { err "$*"; exit 1; }

# --- CLI Overrides ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --talosconfig) TALOSCONFIG="$2"; shift 2 ;;
    --kubeconfig)  KUBECONFIG="$2";  shift 2 ;;
    *) die "Unknown argument: $1 (usage: --talosconfig <path> --kubeconfig <path>)" ;;
  esac
done

# --- Preflight ---
log "verify-cluster: starting"
log "  talosconfig: ${TALOSCONFIG}"
log "  kubeconfig:  ${KUBECONFIG}"
log "  expected nodes: ${EXPECTED_NODES}"

command -v talosctl >/dev/null 2>&1 || die "talosctl not found in PATH"
command -v kubectl   >/dev/null 2>&1 || die "kubectl not found in PATH"

[ -f "$TALOSCONFIG" ] || die "talosconfig not found at ${TALOSCONFIG}"
[ -f "$KUBECONFIG" ]  || die "kubeconfig not found at ${KUBECONFIG}"

# --- Phase 1: Talos cluster health ---
log "Phase 1: Running talosctl health check (timeout: 10m)"
talosctl \
  --talosconfig "$TALOSCONFIG" \
  health \
  --wait-timeout 10m \
  --server=false
HEALTH_EXIT=$?

if [ "$HEALTH_EXIT" -ne 0 ]; then
  die "talosctl health check failed with exit code ${HEALTH_EXIT}"
fi
log "talosctl health check: PASSED"

# --- Phase 2: Kubernetes node inspection ---
log "Phase 2: Inspecting Kubernetes node status via kubectl"

KUBE_OUTPUT=$(kubectl \
  --kubeconfig "$KUBECONFIG" \
  get nodes \
  -o wide \
  --no-headers 2>&1) || die "kubectl get nodes failed: ${KUBE_OUTPUT}"

# Count Ready nodes and total nodes
READY_COUNT=0
TOTAL_COUNT=0

while IFS= read -r line; do
  [ -z "$line" ] && continue
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  # Column 2 is STATUS in kubectl get nodes -o wide --no-headers output
  STATUS=$(echo "$line" | awk '{print $2}')
  if [ "$STATUS" = "Ready" ]; then
    READY_COUNT=$((READY_COUNT + 1))
  fi
done <<< "$KUBE_OUTPUT"

# Print summary table to stdout
echo ""
echo "=== Talos Cluster Node Summary ==="
printf "%-25s %-10s %-15s %-18s %s\n" "NAME" "STATUS" "ROLES" "INTERNAL-IP" "AGE"
printf "%-25s %-10s %-15s %-18s %s\n" "------" "------" "-----" "-----------" "---"
kubectl --kubeconfig "$KUBECONFIG" get nodes -o wide --no-headers \
  | awk '{printf "%-25s %-10s %-15s %-18s %s\n", $1, $2, $3, $6, $5}'
echo "=================================="
echo ""

# --- Phase 3: Assertions ---
FAILED=0

if [ "$TOTAL_COUNT" -ne "$EXPECTED_NODES" ]; then
  err "Expected ${EXPECTED_NODES} nodes, found ${TOTAL_COUNT}"
  FAILED=1
fi

if [ "$READY_COUNT" -ne "$EXPECTED_NODES" ]; then
  err "${READY_COUNT} of ${TOTAL_COUNT} nodes are Ready (expected all ${EXPECTED_NODES})"
  FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
  log "verify-cluster: ALL CHECKS PASSED (${TOTAL_COUNT} nodes, all Ready)"
else
  die "verify-cluster: ${FAILED} assertion(s) failed"
fi

exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# diagnostic-report.sh — Comprehensive cluster state diagnostic collector
#
# Collects and formats a structured Markdown report of the entire HPA dev
# cluster state. Covers nodes, namespaces, pods, PVCs, services, CRDs,
# Helm releases, and optionally runs all verify-*.sh scripts.
#
# Usage: ./diagnostic-report.sh [--kubeconfig <path>]
#                               [--output-dir <dir>]
#                               [--run-verify]
#                               [--namespace-filter <ns>]
#                               [--verbose]
#                               [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Internal defaults ----------------------------------------------------
OUTPUT_DIR="${PROJECT_ROOT}/.gsd/diagnostics"
RUN_VERIFY=false
NAMESPACE_FILTER=""
VERBOSE=false
REPORT_FILE=""

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)           KUBECONFIG="$2";                        shift 2 ;;
    --output-dir)           OUTPUT_DIR="$2";                        shift 2 ;;
    --run-verify)           RUN_VERIFY=true;                         shift ;;
    --namespace-filter)     NAMESPACE_FILTER="$2";                   shift 2 ;;
    --verbose)              VERBOSE=true;                            shift ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Comprehensive cluster state diagnostic collector for HPA dev cluster."
      echo ""
      echo "Options:"
      echo "  --kubeconfig PATH        Path to kubeconfig"
      echo "  --output-dir DIR         Output directory for report files"
      echo "  --run-verify             Run verify-*.sh scripts and include results"
      echo "  --namespace-filter NS    Only report on a specific namespace"
      echo "  --verbose                Include detailed pod/event info"
      echo "  --help, -h               Show this help message"
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Setup ----------------------------------------------------------------
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
SAFE_TS=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="${OUTPUT_DIR}/report-${SAFE_TS}"
REPORT_FILE="${REPORT_DIR}/diagnostic-report.md"
JSON_FILE="${REPORT_DIR}/diagnostic-data.json"
mkdir -p "${REPORT_DIR}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# Test cluster connectivity
if ! kubectl get nodes > /dev/null 2>&1; then
  die "Cannot reach cluster via kubeconfig at ${KUBECONFIG}"
fi

log "diagnostic-report: starting"
log "  output-dir:  ${REPORT_DIR}"
log "  run-verify:  ${RUN_VERIFY}"
log "  verbose:     ${VERBOSE}"

# ============================================================================
# Section 1: Cluster Overview
# ============================================================================
log "Section 1: Cluster overview"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
K8S_VERSION=$(kubectl version 2>/dev/null | grep "Server Version" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")

# Get detailed node info
NODE_DETAILS=""
while IFS= read -r line; do
  [ -z "${line}" ] && continue
  local name="${line%% *}"
  local roles=$(kubectl get node "${name}" -o jsonpath='{.metadata.labels.kubernetes\.io/role}' 2>/dev/null || echo "worker")
  local kubelet=$(kubectl get node "${name}" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "?")
  local runtime=$(kubectl get node "${name}" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || echo "?")
  local cpu=$(kubectl get node "${name}" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null || echo "?")
  local mem=$(kubectl get node "${name}" -o jsonpath='{.status.capacity.memory}' 2>/dev/null || echo "?")
  local taints=$(kubectl get node "${name}" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null || echo "none")
  NODE_DETAILS="${NODE_DETAILS}
| ${name} | ${roles} | ${kubelet} | ${runtime} | ${cpu} vCPU | ${mem} | ${taints} |"
done < <(kubectl get nodes --no-headers 2>/dev/null)

# ============================================================================
# Section 2: Namespaces and Pods
# ============================================================================
log "Section 2: Namespaces and pods"

NAMESPACE_DATA=""
NAMESPACE_LIST=$(kubectl get ns --no-headers 2>/dev/null | awk '{print $1}' | sort)

# Conditionally filter namespaces
if [ -n "${NAMESPACE_FILTER}" ]; then
  NAMESPACE_LIST=$(echo "${NAMESPACE_LIST}" | grep "${NAMESPACE_FILTER}" || true)
fi

while IFS= read -r ns; do
  [ -z "${ns}" ] && continue
  # Skip system namespaces unless verbose
  case "${ns}" in
    kube-system|kube-public|kube-node-lease)
      [ "${VERBOSE}" = false ] && continue
      ;;
  esac

  local pod_count=$(kubectl -n "${ns}" get pods --no-headers 2>/dev/null | wc -l)
  local ready_pods=$(kubectl -n "${ns}" get pods --no-headers 2>/dev/null | awk '{print $2}' | grep -cE '^[0-9]+/[0-9]+$' || echo "0")
  local deploy_count=$(kubectl -n "${ns}" get deployments --no-headers 2>/dev/null | wc -l)
  local sts_count=$(kubectl -n "${ns}" get statefulsets --no-headers 2>/dev/null | wc -l)
  local ds_count=$(kubectl -n "${ns}" get daemonsets --no-headers 2>/dev/null | wc -l)
  local pvc_count=$(kubectl -n "${ns}" get pvc --no-headers 2>/dev/null | wc -l)

  local ns_status=""
  if [ "${pod_count}" -eq 0 ]; then
    ns_status="empty"
  elif [ "${ready_pods}" -eq "${pod_count}" ]; then
    ns_status="healthy"
  else
    ns_status="${ready_pods}/${pod_count} ready"
  fi

  NAMESPACE_DATA="${NAMESPACE_DATA}
| ${ns} | ${deploy_count} deploys / ${sts_count} sts / ${ds_count} ds | ${pod_count} pods (${ns_status}) | ${pvc_count} PVCs |"

  # Detailed pod info for non-healthy namespaces (if verbose)
  if [ "${VERBOSE}" = true ] || [ "${ready_pods}" -ne "${pod_count}" ]; then
    local not_ready=$(kubectl -n "${ns}" get pods --no-headers 2>/dev/null | grep -v -E '\s+[0-9]+/[0-9]+\s+Running' || true)
    if [ -n "${not_ready}" ]; then
      NAMESPACE_DATA="${NAMESPACE_DATA}
    _Not ready:_"
      while IFS= read -r pod_line; do
        [ -z "${pod_line}" ] && continue
        local pname=$(echo "${pod_line}" | awk '{print $1}')
        local pstatus=$(echo "${pod_line}" | awk '{print $3}')
        local pready=$(echo "${pod_line}" | awk '{print $2}')
        local prestart=$(echo "${pod_line}" | awk '{print $6}')
        NAMESPACE_DATA="${NAMESPACE_DATA}
    _ ${pname}: ${pstatus} (${pready}) [${prestart}]_"
      done <<< "${not_ready}"
    fi
  fi
done <<< "${NAMESPACE_LIST}"

# ============================================================================
# Section 3: LoadBalancer Services
# ============================================================================
log "Section 3: LoadBalancer services"

LB_DATA=""
while IFS= read -r line; do
  [ -z "${line}" ] && continue
  local svc_ns=$(echo "${line}" | awk '{print $1}')
  local svc_name=$(echo "${line}" | awk '{print $2}')
  local svc_ip=$(kubectl -n "${svc_ns}" get svc "${svc_name}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  local svc_ports=$(kubectl -n "${svc_ns}" get svc "${svc_name}" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "?")
  LB_DATA="${LB_DATA}
| ${svc_ns}/${svc_name} | ${svc_ip} | ${svc_ports} |"
done < <(kubectl get svc --all-namespaces 2>/dev/null | grep LoadBalancer || echo "")

# ============================================================================
# Section 4: CRD Presence Check
# ============================================================================
log "Section 4: CRD presence check"

EXPECTED_CRDS=(
  "ciliumnetworkpolicies.cilium.io"
  "cephclusters.ceph.rook.io"
  "storageclasses.rook.io"
  "certificates.cert-manager.io"
  "knativeservings.operator.knative.dev"
  "spinapps.core.spinoperator.dev"
  "kafkas.kafka.strimzi.io"
  "kafkatopics.kafka.strimzi.io"
  "applications.argoproj.io"
  "projects.kargo.akuity.io"
  "securitypolicies.gateway.envoyproxy.io"
  "clickhouseinstallations.clickhouse.altinity.com"
  "pulsar-clusters"
)

CRD_DATA=""
for crd in "${EXPECTED_CRDS[@]}"; do
  if kubectl get crd "${crd}" > /dev/null 2>&1; then
    CRD_DATA="${CRD_DATA}
| ✅ | ${crd} | present |"
  else
    CRD_DATA="${CRD_DATA}
| ❌ | ${crd} | missing |"
  fi
done

# ============================================================================
# Section 5: Helm Releases
# ============================================================================
log "Section 5: Helm releases"

HELM_DATA=""
if command -v helm >/dev/null 2>&1; then
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    # Format: namespace, name, revision, updated, status, chart, app_version
    local h_ns=$(echo "${line}" | awk '{print $1}')
    local h_name=$(echo "${line}" | awk '{print $2}')
    local h_status=$(echo "${line}" | awk '{print $8}')
    local h_chart=$(echo "${line}" | awk '{print $9}')
    local h_app=$(echo "${line}" | awk '{print $10}')

    # Check if status is deployed/failed
    if [ "${h_status}" = "deployed" ]; then
      HELM_DATA="${HELM_DATA}
| ✅ | ${h_ns}/${h_name} | ${h_chart} | ${h_app:-?} | deployed |"
    else
      HELM_DATA="${HELM_DATA}
| ❌ | ${h_ns}/${h_name} | ${h_chart} | ${h_app:-?} | ${h_status} |"
    fi
  done < <(helm list --all-namespaces -q 2>/dev/null && helm list --all-namespaces --short 2>/dev/null && helm ls -A --no-headers 2>/dev/null || echo "")
fi

# Fallback: try helm ls with explicit format
HELM_LIST=$(helm ls -A --no-headers 2>/dev/null | head -5)
if [ -n "${HELM_LIST}" ]; then
  HELM_DATA=""
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    HELM_DATA="${HELM_DATA}
| ${line} |"
  done <<< "${HELM_LIST}"
fi

# ============================================================================
# Section 6: Events
# ============================================================================
log "Section 6: Events"

EVENT_DATA=""
EVENTS=$(kubectl get events --all-namespaces --no-headers 2>/dev/null | grep -i "warning\|error\|fail" | head -20 || true)
if [ -n "${EVENTS}" ]; then
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    EVENT_DATA="${EVENT_DATA}
| ${line} |"
  done <<< "${EVENTS}"
else
  EVENT_DATA="No warnings or errors in recent events."
fi

# ============================================================================
# Section 7: Verify Script Results (optional)
# ============================================================================
VERIFY_DATA=""
if [ "${RUN_VERIFY}" = true ]; then
  log "Section 7: Running verify-*.sh scripts..."

  VERIFY_SCRIPTS=(
    "verify-cilium.sh" "verify-ceph.sh" "verify-harbor.sh"
    "verify-infisical.sh" "verify-runtimes.sh"
    "verify-kafka.sh" "verify-spegel.sh"
    "verify-casdoor.sh" "verify-casbin.sh"
    "verify-gateway.sh" "verify-security-policy.sh" "verify-gitops.sh"
    "verify-workloads.sh" "verify-streaming-workload.sh"
    "verify-yugabytedb.sh" "verify-hasura.sh"
    "verify-pulsar.sh" "verify-clickhouse.sh" "verify-analytics.sh"
  )

  for vs in "${VERIFY_SCRIPTS[@]}"; do
    if [ -f "${SCRIPT_DIR}/${vs}" ]; then
      log "  Running ${vs}..."
      timeout 120 bash "${SCRIPT_DIR}/${vs}" 2>&1 > /tmp/verify-$$.txt
      local exit_code=$?
      local verdict=$(grep -E "verdict:|Overall verdict:" /tmp/verify-$$.txt 2>/dev/null | head -1 | cut -c1-60)
      verdict="${verdict:-exit=${exit_code}}"
      VERIFY_DATA="${VERIFY_DATA}
| ${vs} | $([ ${exit_code} -eq 0 ] && echo '✅' || echo '❌') | ${verdict} |"
      rm -f /tmp/verify-$$.txt
    else
      VERIFY_DATA="${VERIFY_DATA}
| ${vs} | ⚪ | script not found |"
    fi
  done
fi

# ============================================================================
# Write Report
# ============================================================================
log "Writing report to ${REPORT_FILE}"

cat > "${REPORT_FILE}" <<REPORTEOF
# Diagnostic Report

**Generated:** ${TIMESTAMP}
**Host:** $(hostname)
**K8s Version:** ${K8S_VERSION}
**Nodes:** ${NODE_COUNT}
**Kubeconfig:** ${KUBECONFIG}

---

## 1. Cluster Overview

| Node | Roles | Kubelet | Runtime | CPU | Memory | Taints |
|------|-------|---------|---------|-----|--------|--------|${NODE_DETAILS}

## 2. Namespaces and Workloads

| Namespace | Workloads | Pods | PVCs |
|-----------|-----------|------|------|${NAMESPACE_DATA}

## 3. LoadBalancer Services

| Service | External IP | Ports |
|---------|-------------|-------|${LB_DATA}

## 4. CRD Presence

| Status | CRD | Notes |
|--------|-----|-------|${CRD_DATA}

## 5. Helm Releases

| Status | Release | Chart | App Version | Status |
|--------|---------|-------|-------------|--------|${HELM_DATA}

## 6. Recent Events (Warnings/Errors)

${EVENT_DATA}

REPORTEOF

if [ -n "${VERIFY_DATA}" ]; then
  cat >> "${REPORT_FILE}" <<EOF

## 7. Verification Script Results

| Script | Result | Detail |
|--------|--------|--------|${VERIFY_DATA}
EOF
fi

# ============================================================================
# Collect Raw Data for Programmatic Use
# ============================================================================
log "Collecting raw diagnostic data..."

# Node status JSON
kubectl get nodes -o json > "${REPORT_DIR}/nodes.json" 2>/dev/null || true
# Pod status JSON
kubectl get pods --all-namespaces -o json > "${REPORT_DIR}/pods.json" 2>/dev/null || true
# PVCs
kubectl get pvc --all-namespaces -o json > "${REPORT_DIR}/pvcs.json" 2>/dev/null || true
# Events
kubectl get events --all-namespaces > "${REPORT_DIR}/events.txt" 2>/dev/null || true
# Helm list
helm ls -A > "${REPORT_DIR}/helm-list.txt" 2>/dev/null || true
# Resource usage (if metrics server is available)
kubectl top nodes 2>/dev/null > "${REPORT_DIR}/resource-usage.txt" || echo "metrics-server not available" > "${REPORT_DIR}/resource-usage.txt"

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Diagnostic Report Summary ==="
echo "  Report:     ${REPORT_FILE}"
echo "  Data dir:   ${REPORT_DIR}"
echo "  Nodes:      ${NODE_COUNT}"
echo "  K8s:        ${K8S_VERSION}"
if [ -n "${LB_DATA}" ]; then
  echo "  LB IPs:     $(echo "${LB_DATA}" | grep -c '|' || echo "0") services"
fi
echo "  Helm:       $(echo "${HELM_DATA}" | grep -c '✅' 2>/dev/null || echo "0") deployed releases"
echo "  CRDs:       $(echo "${CRD_DATA}" | grep -c '✅' 2>/dev/null || echo "0")/${#EXPECTED_CRDS[@]} expected present"
echo ""

echo "  View: less ${REPORT_FILE}"
echo "================================="

log "diagnostic-report: completed successfully"
exit 0

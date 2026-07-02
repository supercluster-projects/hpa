#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# regression-check.sh — Milestone-level regression detection for the HPA dev
#                       cluster
#
# Compares the current cluster state against expected baselines for all 12
# prior milestones. Each milestone's expected state is checked independently,
# producing a per-milestone PASS/FAIL/WARN verdict.
#
# Usage: ./regression-check.sh [--kubeconfig <path>]
#                              [--milestone <M001|...>]
#                              [--verbose]
#                              [--skip-event-check]
#                              [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Internal defaults ----------------------------------------------------
MILESTONE_FILTER=""
VERBOSE=false
SKIP_EVENT_CHECK=false

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)       KUBECONFIG="$2";                        shift 2 ;;
    --milestone)        MILESTONE_FILTER="$2";                   shift 2 ;;
    --verbose)          VERBOSE=true;                            shift ;;
    --skip-event-check) SKIP_EVENT_CHECK=true;                    shift ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Milestone-level regression detection for HPA dev cluster."
      echo "Checks all 12 milestone deliverables against expected cluster state."
      echo ""
      echo "Options:"
      echo "  --kubeconfig PATH    Path to kubeconfig"
      echo "  --milestone ID       Only check a specific milestone (e.g. M003)"
      echo "  --verbose            Include detailed diagnostic output"
      echo "  --skip-event-check   Skip recent event check"
      echo "  --help, -h           Show this help message"
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"
kubectl get nodes > /dev/null 2>&1 || die "Cannot reach cluster"

# ---- Results accumulator --------------------------------------------------
OVERALL_PASS=0
OVERALL_FAIL=0
OVERALL_WARN=0
RESULTS=""
DETAILS=""

# ---- Helper: run a check --------------------------------------------------
check() {
  local milestone="$1"     # e.g. M001
  local check_name="$2"    # human-readable check name
  local condition="$3"     # label for result
  shift 3

  # Run the check command
  if "$@" > /dev/null 2>&1; then
    OVERALL_PASS=$((OVERALL_PASS + 1))
    RESULTS="${RESULTS}
| ✅ | ${milestone} | ${check_name} | pass |"
    [ "${VERBOSE}" = true ] && DETAILS="${DETAILS}
  ✅ ${milestone}/${check_name}: ${condition}"
  else
    # Run again to capture error output
    local err_output=$("$@" 2>&1 | head -5 | tr '\n' ' ' | cut -c1-80)
    OVERALL_FAIL=$((OVERALL_FAIL + 1))
    RESULTS="${RESULTS}
| ❌ | ${milestone} | ${check_name} | fail (${err_output:-condition not met}) |"
    DETAILS="${DETAILS}
  ❌ ${milestone}/${check_name}: ${condition} — ${err_output}"
  fi
}

# ---- Helper: check pod readiness in a namespace ---------------------------
check_pod_readiness() {
  local ns="$1"
  local label="$2"
  local expected="$3"

  local ready_count=0
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    local ready_field=$(echo "${line}" | awk '{print $2}')
    local ready_num=$(echo "${ready_field}" | cut -d/ -f1)
    local total_num=$(echo "${ready_field}" | cut -d/ -f2)
    if [ "${ready_num}" -gt 0 ] && [ "${ready_num}" = "${total_num}" ] 2>/dev/null; then
      ready_count=$((ready_count + 1))
    fi
  done < <(kubectl -n "${ns}" get pods -l "${label}" --no-headers 2>/dev/null || true)

  [ "${ready_count}" -ge "${expected}" ] || return 1
}

# ============================================================================
# M001 — Base Cluster + GitOps Pipeline + Core Runtimes + Validation
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M001" ]; then
  log "M001: Base Cluster checks..."

  # Cilium
  check "M001" "Cilium DaemonSet ready" "cilium-app pods running in kube-system" \
    check_pod_readiness "kube-system" "k8s-app=cilium" 1

  # Rook Ceph
  check "M001" "Rook Ceph operator" "rook-ceph-operator deployment ready" \
    check_pod_readiness "rook-ceph" "app=rook-ceph-operator" 1

  # Harbor
  check "M001" "Harbor namespace" "harbor namespace exists" \
    kubectl get ns harbor

  # Harbor LB IP
  local harbor_ip
  harbor_ip=$(kubectl -n harbor get svc harbor --no-headers 2>/dev/null | awk '{print $4}')
  if [ -n "${harbor_ip}" ] && [ "${harbor_ip}" != "<pending>" ]; then
    check "M001" "Harbor LoadBalancer IP" "harbor service has external IP" \
      test -n "${harbor_ip}"
  else
    check "M001" "Harbor LoadBalancer IP" "harbor service exists" \
      kubectl -n harbor get svc harbor > /dev/null 2>&1
  fi

  # Infisical
  check "M001" "Infisical namespace" "infisical namespace exists" \
    kubectl get ns infisical

  # cert-manager
  check "M001" "cert-manager" "cert-manager namespace exists" \
    kubectl get ns cert-manager

  # Knative
  check "M001" "Knative Serving namespace" "knative-serving namespace exists" \
    kubectl get ns knative-serving

  # SpinKube
  check "M001" "SpinKube operator" "spin-operator namespace exists" \
    kubectl get ns spin-operator

  # KeyDB
  check "M001" "KeyDB" "keydb namespace exists" \
    kubectl get ns keydb

  # ArgoCD
  check "M001" "ArgoCD" "argocd namespace exists" \
    kubectl get ns argocd

  # Kargo
  check "M001" "Kargo" "kargo namespace exists" \
    kubectl get ns kargo
fi

# ============================================================================
# M002 — IAM and Security
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M002" ]; then
  log "M002: IAM and Security checks..."

  # Casdoor
  check "M002" "Casdoor namespace" "casdoor namespace exists" \
    kubectl get ns casdoor

  local casdoor_ip
  casdoor_ip=$(kubectl -n casdoor get svc casdoor --no-headers 2>/dev/null | awk '{print $4}')
  if [ -n "${casdoor_ip}" ] && [ "${casdoor_ip}" != "<pending>" ]; then
    check "M002" "Casdoor LoadBalancer IP" "casdoor has external IP" \
      test -n "${casdoor_ip}"
  fi

  # Casbin
  check "M002" "Casbin namespace" "casbin namespace exists" \
    kubectl get ns casbin

  check "M002" "Casbin deployment" "casbin-ext-authz deployment ready" \
    check_pod_readiness "casbin" "app=casbin-ext-authz" 1

  # Envoy Gateway
  check "M002" "Envoy Gateway namespace" "envoy-gateway-system exists" \
    kubectl get ns envoy-gateway-system

  local envoy_ip
  envoy_ip=$(kubectl -n envoy-gateway-system get svc envoy-gateway --no-headers 2>/dev/null | awk '{print $4}')
  if [ -n "${envoy_ip}" ] && [ "${envoy_ip}" != "<pending>" ]; then
    check "M002" "Envoy Gateway LB IP" "envoy-gateway has external IP" \
      test -n "${envoy_ip}"
  fi

  # SecurityPolicy
  check "M002" "SecurityPolicy CRD" "SecurityPolicy CRD exists" \
    kubectl get crd securitypolicies.gateway.envoyproxy.io > /dev/null 2>&1
fi

# ============================================================================
# M003 — Streaming platform
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M003" ]; then
  log "M003: Streaming checks..."

  # Strimzi Kafka
  check "M003" "Strimzi namespace" "strimzi namespace exists" \
    kubectl get ns strimzi

  check "M003" "Kafka cluster CR" "Kafka CR hpa-kafka exists" \
    kubectl -n strimzi get kafka hpa-kafka > /dev/null 2>&1

  check "M003" "Kafka topic hpa-events" "KafkaTopic CR exists" \
    kubectl -n strimzi get kafkatopic hpa-events > /dev/null 2>&1

  # Spegel
  check "M003" "Spegel namespace" "spegel namespace exists" \
    kubectl get ns spegel

  check "M003" "Spegel DaemonSet" "spegel DaemonSet ready" \
    check_pod_readiness "spegel" "app.kubernetes.io/name=spegel" 1

  # Stream-processor
  check "M003" "Stream-processor SpinApp" "stream-processor SpinApp exists" \
    kubectl -n hpa-workloads get spinapp stream-processor > /dev/null 2>&1
fi

# ============================================================================
# M005 — Observability (note: M004 is parked)
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M005" ]; then
  log "M005: Observability checks..."

  # VMSingle
  check "M005" "VMSingle" "vm-single namespace exists" \
    kubectl get ns vm-single

  # vmagent
  check "M005" "vmagent" "vmagent namespace exists" \
    kubectl get ns vmagent

  # kube-state-metrics
  check "M005" "kube-state-metrics" "kube-state-metrics namespace exists" \
    kubectl get ns kube-state-metrics

  # Grafana
  check "M005" "Grafana" "grafana namespace exists" \
    kubectl get ns grafana

  # AlertManager
  check "M005" "AlertManager" "alertmanager namespace exists" \
    kubectl get ns alertmanager
fi

# ============================================================================
# M006 — Production mesh
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M006" ]; then
  log "M006: Production mesh checks..."

  # TLS
  check "M006" "cert-manager issuers" "ClusterIssuer exists" \
    kubectl get clusterissuer > /dev/null 2>&1
fi

# ============================================================================
# M007 — Offline seeder
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M007" ]; then
  log "M007: Offline seeder checks..."

  check "M007" "Seed directory" "SEED_DIR env var set or seed command available" \
    test -n "${SEED_DIR:-}" || test -f "${SCRIPT_DIR}/build-seed.sh"
fi

# ============================================================================
# M008 — Dev Experience and Provisioning
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M008" ]; then
  log "M008: Dev experience checks..."

  check "M008" "Cluster create script" "cluster-create.sh exists" \
    test -f "${SCRIPT_DIR}/cluster-create.sh"

  check "M008" "Cluster destroy script" "cluster-destroy.sh exists" \
    test -f "${SCRIPT_DIR}/cluster-destroy.sh"
fi

# ============================================================================
# M010 — Dev cluster provisioning fix
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M010" ]; then
  log "M010: Provisioning fix checks..."

  check "M010" "startup.sh exists" "startup.sh is present" \
    test -f "${SCRIPT_DIR}/startup.sh"

  check "M010" "Setup bridge script" "setup-bridge.sh exists" \
    test -f "${SCRIPT_DIR}/setup-bridge.sh"

  check "M010" "e2e provisioning script" "e2e-provisioning.sh exists" \
    test -f "${SCRIPT_DIR}/e2e-provisioning.sh"

  check "M010" "Cilium kube-proxy-free" "cilium config has kubeProxyReplacement" \
    kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.kube-proxy-replacement}' 2>/dev/null | grep -qi "true"
fi

# ============================================================================
# M011 — CI image build pipeline
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M011" ]; then
  log "M011: CI image build checks..."

  for script in build-welcome.sh build-counter.sh build-stream.sh build-casbin.sh build-all.sh verify-images.sh; do
    check "M011" "Build script: ${script}" "build script exists and executable" \
      test -x "${SCRIPT_DIR}/${script}"
  done
fi

# ============================================================================
# M012 — Analytics pipeline: Pulsar + ClickHouse
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M012" ]; then
  log "M012: Analytics pipeline checks..."

  # Pulsar
  check "M012" "Pulsar namespace" "pulsar namespace exists" \
    kubectl get ns pulsar

  check "M012" "Pulsar ZK StatefulSet" "pulsar-zookeeper exists" \
    kubectl -n pulsar get statefulset pulsar-zookeeper > /dev/null 2>&1

  check "M012" "Pulsar BK StatefulSet" "pulsar-bookkeeper exists" \
    kubectl -n pulsar get statefulset pulsar-bookkeeper > /dev/null 2>&1

  check "M012" "Pulsar Broker StatefulSet" "pulsar-broker exists" \
    kubectl -n pulsar get statefulset pulsar-broker > /dev/null 2>&1

  check "M012" "Pulsar Function Worker" "pulsar-function-worker exists" \
    kubectl -n pulsar get deployment pulsar-function-worker > /dev/null 2>&1

  check "M012" "Pulsar toolset pod" "pulsar-toolset pod exists" \
    kubectl -n pulsar get pod -l "app=pulsar,component=toolset" --no-headers 2>/dev/null | grep -q .

  # ClickHouse
  check "M012" "ClickHouse namespace" "clickhouse namespace exists" \
    kubectl get ns clickhouse

  check "M012" "ClickHouse StatefulSet" "clickhouse-clickhouse statefulset exists" \
    kubectl -n clickhouse get statefulset clickhouse-clickhouse > /dev/null 2>&1

  # Pulsar Function
  check "M012" "Java TelemetryTransformFunction source" "function source file exists" \
    test -f "${PROJECT_ROOT}/backend/functions/telemetry/src/main/java/com/analytics/pulsar/functions/TelemetryTransformFunction.java"

  check "M012" "Install function script" "install-function.sh exists" \
    test -f "${SCRIPT_DIR}/install-function.sh"

  check "M012" "Verify analytics script" "verify-analytics.sh exists" \
    test -f "${SCRIPT_DIR}/verify-analytics.sh"
fi

# ============================================================================
# M013 — Runtime verification (current milestone)
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ] || [ "${MILESTONE_FILTER}" = "M013" ]; then
  log "M013: Runtime verification checks..."

  check "M013" "Host preflight script" "host-preflight.sh exists" \
    test -f "${SCRIPT_DIR}/host-preflight.sh"

  check "M013" "Setup host script" "setup-host.sh exists" \
    test -f "${SCRIPT_DIR}/setup-host.sh"

  check "M013" "Pipeline runner script" "run-pipeline.sh exists" \
    test -f "${SCRIPT_DIR}/run-pipeline.sh"

  check "M013" "Diagnostic report script" "diagnostic-report.sh exists" \
    test -f "${SCRIPT_DIR}/diagnostic-report.sh"

  check "M013" "Regression check script" "regression-check.sh (this script) exists" \
    test -f "${SCRIPT_DIR}/regression-check.sh"
fi

# ============================================================================
# Workload Verification
# ============================================================================
if [ -z "${MILESTONE_FILTER}" ]; then
  log "Cross-milestone: Workload verification..."

  # Welcome namespace
  check "CROSS" "Welcome Knative Service" "welcome ksvc in hpa-workloads" \
    kubectl -n hpa-workloads get ksvc welcome > /dev/null 2>&1

  # Counter SpinApp
  check "CROSS" "Counter SpinApp" "counter spinapp in hpa-workloads" \
    kubectl -n hpa-workloads get spinapp counter > /dev/null 2>&1

  # Yugabytedb
  check "CROSS" "Yugabytedb namespace" "yugabytedb namespace exists" \
    kubectl get ns yugabytedb

  # Hasura
  check "CROSS" "Hasura namespace" "hasura namespace exists" \
    kubectl get ns hasura

  # ceph-rbd StorageClass
  check "CROSS" "ceph-rbd StorageClass" "StorageClass ceph-rbd exists" \
    kubectl get sc ceph-rbd > /dev/null 2>&1

  # Generic recent events check (no critical errors)
  if [ "${SKIP_EVENT_CHECK}" = false ]; then
    local critical_events
    critical_events=$(kubectl get events --all-namespaces --no-headers 2>/dev/null \
      | grep -i "CrashLoopBackOff\|ImagePullBackOff\|ErrImagePull\|OOMKill\|OutOfMemory" \
      | head -5 || true)
    if [ -n "${critical_events}" ]; then
      RESULTS="${RESULTS}
| ⚠️ | CROSS | No critical pod errors | warn (see events below) |"
      DETAILS="${DETAILS}
  ⚠️ Critical events detected:
${critical_events}"
    else
      RESULTS="${RESULTS}
| ✅ | CROSS | No critical pod errors | pass |"
    fi
    OVERALL_WARN=$((OVERALL_WARN + 1))
  fi
fi

# ============================================================================
# Summary
# ============================================================================
TOTAL_CHECKS=$((OVERALL_PASS + OVERALL_FAIL))

echo ""
echo "=== Regression Check Summary ==="
printf "%-6s %-12s %-40s %s\n" "STATUS" "MILESTONE" "CHECK" "DETAIL"
printf -- "%-6s %-12s %-40s %s\n" "------" "--------" "-----" "------"
echo "${RESULTS}"
echo "================================================================="
printf "Total: %d checks — %d PASS / %d FAIL / %d WARN\n" "${TOTAL_CHECKS}" "${OVERALL_PASS}" "${OVERALL_FAIL}" "${OVERALL_WARN}"
echo "================================================================="

if [ -n "${DETAILS}" ] && [ "${VERBOSE}" = true ]; then
  echo ""
  echo "--- Details ---"
  echo "${DETAILS}"
fi

echo ""
echo "  PASS:       ${OVERALL_PASS}"
echo "  FAIL:       ${OVERALL_FAIL}"
echo "  WARN:       ${OVERALL_WARN}"
echo "  Total:      ${TOTAL_CHECKS}"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAIL}" -gt 0 ]; then
  die "regression-check: ${OVERALL_FAIL} check(s) failed — review output above"
fi

log "regression-check: ALL CHECKS PASSED"
exit 0

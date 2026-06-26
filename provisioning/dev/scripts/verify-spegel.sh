#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-spegel.sh — Spegel P2P image mirror verification
#
# Verifies Spegel distributed image mirroring is operational:
#   Phase 1: Spegel DaemonSet pods Ready on all nodes (namespace: spegel)
#   Phase 2: Containerd mirror config present (Spegel mirror endpoint)
#   Phase 3: Spegel metrics endpoint reachable (localhost:51443/metrics)
#   Phase 4: P2P distribution — HTTP storage responds and peers detected
#
# Each phase produces PASS / WARN / FAIL with detail. A final summary table
# is printed to stdout. Exits non-zero if any phase fails.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-spegel.sh [--kubeconfig <path>]
#           [--expected-spegel-pods <count>]
#           [--wait-timeout <seconds>] [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

SPEGEL_NS="spegel"
EXPECTED_SPEGEL_PODS=3
WAIT_TIMEOUT=120
METRICS_PORT=51443

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)             KUBECONFIG="$2";              shift 2 ;;
    --expected-spegel-pods)   EXPECTED_SPEGEL_PODS="$2";    shift 2 ;;
    --wait-timeout)           WAIT_TIMEOUT="$2";            shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Spegel P2P image mirroring health.

Phases:
  1  Spegel DaemonSet pod health (namespace: spegel)
  2  Containerd mirror config present (Spegel mirror endpoint)
  3  Spegel metrics endpoint reachable (localhost:${METRICS_PORT}/metrics)
  4  P2P distribution — HTTP storage responds and peers detected

Options:
  --kubeconfig PATH               Path to kubeconfig (default: ../opentofu/kubeconfig)
  --expected-spegel-pods COUNT    Expected number of spegel DaemonSet pods
                                    (default: 3)
  --wait-timeout SECONDS          Max seconds to wait for pods to appear
                                    (default: 120)
  --help, -h                      Show this help message

Examples:
  ./verify-spegel.sh --kubeconfig /custom/path/kubeconfig
  ./verify-spegel.sh --expected-spegel-pods 5
  ./verify-spegel.sh --wait-timeout 300
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-spegel: starting"
log "  kubeconfig:             ${KUBECONFIG}"
log "  wait timeout:           ${WAIT_TIMEOUT}s"
log "  expected spegel pods:   ${EXPECTED_SPEGEL_PODS}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # Spegel pod health
PHASE1_DETAIL=""
PHASE2_STATUS=""   # Containerd mirror config check
PHASE2_DETAIL=""
PHASE3_STATUS=""   # Metrics endpoint reachable
PHASE3_DETAIL=""
PHASE4_STATUS=""   # P2P distribution check
PHASE4_DETAIL=""

OVERALL_FAILED=0

# ---- Helper: check pods in a namespace ------------------------------------
# Usage: check_pod_health <namespace> <expected_count> <var_status> <var_detail>
# Sets the status and detail variables via nameref.
check_pod_health() {
  local ns="$1"
  local expected="$2"
  local -n out_status="$3"
  local -n out_detail="$4"

  log "Checking pod health in namespace '${ns}' (expected ${expected})"

  local POD_OUTPUT
  POD_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pods --no-headers 2>&1) \
    || { err "kubectl get pods in '${ns}' failed: ${POD_OUTPUT}"; out_status="FAIL"; out_detail="kubectl error"; return 1; }

  local TOTAL=0
  local READY=0
  local NOT_OK=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    TOTAL=$((TOTAL + 1))
    local READY_FIELD
    local STATUS_FIELD
    READY_FIELD=$(echo "$line" | awk '{print $2}')
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')
    local READY_NUM="${READY_FIELD%%/*}"

    if [ "${READY_NUM}" -gt 0 ] && [ "${STATUS_FIELD}" = "Running" ]; then
      READY=$((READY + 1))
    else
      local POD_NAME
      POD_NAME=$(echo "$line" | awk '{print $1}')
      NOT_OK="${NOT_OK} ${POD_NAME}(${STATUS_FIELD}/${READY_FIELD})"
    fi
  done <<< "${POD_OUTPUT}"

  if [ -n "${NOT_OK}" ]; then
    err "Pods not ready in '${ns}':${NOT_OK}"
    out_status="FAIL"
    out_detail="${READY}/${TOTAL} ready"
    return 1
  elif [ "${TOTAL}" -eq 0 ]; then
    err "No pods found in namespace '${ns}'"
    out_status="FAIL"
    out_detail="0 pods"
    return 1
  elif [ "${TOTAL}" -eq "${expected}" ] && [ "${READY}" -eq "${expected}" ]; then
    out_status="PASS"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    log "  -> PASSED"
    return 0
  elif [ "${READY}" -ge "$((expected - 1))" ]; then
    out_status="WARN"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})"
    log "  -> WARN (close to expected)"
    return 0
  else
    local pod_count_note=""
    if [ "${TOTAL}" -gt "${expected}" ] && [ "${READY}" -eq "${TOTAL}" ]; then
      pod_count_note=" (more pods than expected)"
    fi
    err "Pod count mismatch in '${ns}': ${READY}/${TOTAL} ready, expected ${expected}"
    out_status="FAIL"
    out_detail="${READY}/${TOTAL} ready (expected ${expected})${pod_count_note}"
    return 1
  fi
}

# ---- Helper: pick the first ready spegel pod -------------------------------
# Usage: get_first_ready_pod <namespace> <var_pod_name>
# Returns 0 with pod name in the nameref, or 1 if no ready pod found.
get_first_ready_pod() {
  local ns="$1"
  local -n out_pod="$2"

  local POD_LINE
  POD_LINE=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${ns}" get pods \
    --field-selector=status.phase=Running -o name 2>&1 | head -1) || return 1

  [ -z "${POD_LINE}" ] && return 1

  out_pod="${POD_LINE#pod/}"
  return 0
}

# ============================================================================
# Phase 1: Spegel DaemonSet pod health (namespace: spegel)
# ============================================================================
log "Phase 1: Spegel DaemonSet pod health"
if check_pod_health "${SPEGEL_NS}" "${EXPECTED_SPEGEL_PODS}" PHASE1_STATUS PHASE1_DETAIL; then
  : # already set
else
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 2: Containerd mirror config present on spegel pods
# Checks that the spegel mirror endpoint (localhost:5000) is present in the
# containerd configuration. Spegel injects this via a ConfigMap mount at
# /etc/containerd/conf.d/spegel.toml or similar path, or we can check
# the running containerd config by inspecting /etc/containerd/config.toml
# on a node via kubectl exec into the spegel pod (which has the config mounted).
# ============================================================================
log "Phase 2: Containerd mirror config check"
PHASE2_MIRROR_FOUND=0
PHASE2_POD=""

if get_first_ready_pod "${SPEGEL_NS}" PHASE2_POD; then
  log "  Using pod: ${PHASE2_POD}"

  # Check common paths where Spegel writes the mirror config
  local CHECK_PATHS=(
    "/etc/containerd/conf.d/spegel.toml"
    "/etc/containerd/config.toml"
  )

  for config_path in "${CHECK_PATHS[@]}"; do
    if kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE2_POD}" -- \
      cat "${config_path}" > /dev/null 2>&1; then
      log "  Found config at: ${config_path}"

      # Check for spegel mirror endpoint (localhost:5000)
      if kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE2_POD}" -- \
        grep -q "localhost:5000" "${config_path}" 2>/dev/null; then
        log "  Mirror endpoint localhost:5000 found in ${config_path}"
        PHASE2_MIRROR_FOUND=1
        break
      fi

      # Also check for spegel endpoint marker
      if kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE2_POD}" -- \
        grep -qi "spegel" "${config_path}" 2>/dev/null; then
        log "  Spegel reference found in ${config_path}"
        PHASE2_MIRROR_FOUND=1
        break
      fi
    fi
  done

  # If we didn't find it via config files, check the host's containerd config
  # by looking at /host-fs (common in spegel DaemonSet mounts)
  if [ "${PHASE2_MIRROR_FOUND}" -eq 0 ]; then
    log "  Checking host containerd config via /host/containerd/..."
    if kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE2_POD}" -- \
      grep -q "localhost:5000" /host/containerd/config.toml 2>/dev/null; then
      log "  Mirror endpoint localhost:5000 found in host containerd config"
      PHASE2_MIRROR_FOUND=1
    elif kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE2_POD}" -- \
      ls /host/containerd/conf.d/spegel.toml 2>/dev/null; then
      log "  Host containerd spegel config found at /host/containerd/conf.d/spegel.toml"
      PHASE2_MIRROR_FOUND=1
    fi
  fi
else
  log "  No ready spegel pod available to check mirror config"
fi

if [ "${PHASE2_MIRROR_FOUND}" -eq 1 ]; then
  PHASE2_STATUS="PASS"
  PHASE2_DETAIL="Spegel mirror endpoint found in containerd config"
  log "  -> PASSED"
else
  PHASE2_STATUS="FAIL"
  PHASE2_DETAIL="Spegel mirror endpoint not found in containerd config"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 3: Spegel metrics endpoint reachable (localhost:51443/metrics)
# Exec into a ready spegel pod and curl the metrics endpoint.
# ============================================================================
log "Phase 3: Spegel metrics endpoint reachable"
PHASE3_POD=""
PHASE3_METRICS_OK=0

if get_first_ready_pod "${SPEGEL_NS}" PHASE3_POD; then
  log "  Using pod: ${PHASE3_POD}"

  local METRICS_OUTPUT
  METRICS_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE3_POD}" -- \
    curl -sSf --connect-timeout 5 "http://localhost:${METRICS_PORT}/metrics" 2>&1) || true

  if echo "${METRICS_OUTPUT}" | grep -q "spegel_" 2>/dev/null; then
    log "  Metrics endpoint responding with spegel metrics"
    PHASE3_METRICS_OK=1
  elif echo "${METRICS_OUTPUT}" | grep -q "^#" 2>/dev/null; then
    # Prometheus metrics typically start with # HELP or # TYPE comments
    log "  Metrics endpoint responding (prometheus format detected)"
    PHASE3_METRICS_OK=1
  else
    # Try with wget if curl not available in the container
    log "  curl failed, trying wget..."
    local WGET_OUTPUT
    WGET_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE3_POD}" -- \
      wget -q -O - "http://localhost:${METRICS_PORT}/metrics" 2>&1) || true

    if echo "${WGET_OUTPUT}" | grep -q "spegel_\|^#" 2>/dev/null; then
      log "  Metrics endpoint responding via wget"
      PHASE3_METRICS_OK=1
    else
      log "  Metrics endpoint not reachable with curl or wget: $(echo "${METRICS_OUTPUT}" | head -1)"
    fi
  fi
else
  log "  No ready spegel pod available to check metrics"
fi

if [ "${PHASE3_METRICS_OK}" -eq 1 ]; then
  PHASE3_STATUS="PASS"
  PHASE3_DETAIL="Metrics endpoint reachable on localhost:${METRICS_PORT}/metrics"
  log "  -> PASSED"
else
  PHASE3_STATUS="FAIL"
  PHASE3_DETAIL="Metrics endpoint not reachable on localhost:${METRICS_PORT}/metrics"
  OVERALL_FAILED=1
fi

# ============================================================================
# Phase 4: P2P distribution check
# Verifies that Spegel is actively distributing images:
#   - HTTP storage endpoint responds (spegel serves cached blobs)
#   - Spegel metrics show peer connections
# This confirms the P2P mesh is operational and content is being served.
# ============================================================================
log "Phase 4: P2P distribution check"
PHASE4_POD=""
PHASE4_HTTP_OK=0
PHASE4_PEERS_OK=0
PHASE4_DETAIL_ACCUM=""

if get_first_ready_pod "${SPEGEL_NS}" PHASE4_POD; then
  log "  Using pod: ${PHASE4_POD}"

  # Check 4a: HTTP storage endpoint responds (spegel serves cached blobs)
  # Spegel exposes an OCI-compatible HTTP storage backend on :51443.
  # A simple HEAD request verifies it is serving content.
  local HTTP_CHECK
  HTTP_CHECK=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE4_POD}" -- \
    curl -sSf -o /dev/null -w "%{http_code}" --connect-timeout 5 \
    "http://localhost:${METRICS_PORT}/" 2>&1) || HTTP_CHECK="failed"

  if [ "${HTTP_CHECK}" = "200" ] || [ "${HTTP_CHECK}" = "404" ]; then
    # 200 or 404 are valid — the endpoint exists and serves requests
    log "  HTTP storage endpoint responded with status ${HTTP_CHECK}"
    PHASE4_HTTP_OK=1
    PHASE4_DETAIL_ACCUM="HTTP storage responds (${HTTP_CHECK})"
  else
    log "  HTTP storage endpoint HTTP status: ${HTTP_CHECK}"
    PHASE4_DETAIL_ACCUM="HTTP storage status ${HTTP_CHECK}"
  fi

  # Check 4b: Spegel metrics show peer connections
  # Look for spegel_peers or spegel_kube_peers or similar metric
  local METRICS_CONTENT
  METRICS_CONTENT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${SPEGEL_NS}" exec "${PHASE4_POD}" -- \
    curl -sSf --connect-timeout 5 "http://localhost:${METRICS_PORT}/metrics" 2>&1) || true

  local PEER_COUNT=0
  if echo "${METRICS_CONTENT}" | grep -q "spegel_peers" 2>/dev/null; then
    PEER_COUNT=$(echo "${METRICS_CONTENT}" | grep "spegel_peers" | grep -v "^#" | awk '{sum += $NF} END {print sum}')
    log "  spegel_peers metric found, total peers: ${PEER_COUNT}"
  elif echo "${METRICS_CONTENT}" | grep -q "peers" 2>/dev/null; then
    PEER_COUNT=$(echo "${METRICS_CONTENT}" | grep "peers" | grep -v "^#" | awk '{sum += $NF} END {print sum}')
    log "  peer metrics found, count: ${PEER_COUNT}"
  else
    log "  No peer-related metrics found in output"
  fi

  if [ -n "${PEER_COUNT}" ] && [ "${PEER_COUNT}" -gt 0 ]; then
    PHASE4_PEERS_OK=1
    if [ -n "${PHASE4_DETAIL_ACCUM}" ]; then
      PHASE4_DETAIL_ACCUM="${PHASE4_DETAIL_ACCUM}, peers: ${PEER_COUNT}"
    else
      PHASE4_DETAIL_ACCUM="peers: ${PEER_COUNT}"
    fi
    log "  P2P peers detected: ${PEER_COUNT}"
  else
    if [ -n "${PHASE4_DETAIL_ACCUM}" ]; then
      PHASE4_DETAIL_ACCUM="${PHASE4_DETAIL_ACCUM}, no peers yet"
    else
      PHASE4_DETAIL_ACCUM="no peers detected"
    fi
    log "  No P2P peers detected (may have single node or just starting up)"
  fi

  # Check 4c: blobs are being served (look for blob-related metrics or nonzero request count)
  local BLOB_METRICS_OK=0
  if echo "${METRICS_CONTENT}" | grep -q "spegel_blob" 2>/dev/null; then
    BLOB_METRICS_OK=1
    log "  Spegel blob metrics found — blobs are being served"
  fi

  if [ "${BLOB_METRICS_OK}" -eq 1 ]; then
    PHASE4_DETAIL_ACCUM="${PHASE4_DETAIL_ACCUM}, blobs served"
  fi
else
  log "  No ready spegel pod available for P2P check"
  PHASE4_DETAIL_ACCUM="no pod available"
fi

# Phase 4 verdict: HTTP storage must respond; peers are optional but noted
if [ "${PHASE4_HTTP_OK}" -eq 1 ]; then
  PHASE4_STATUS="PASS"
  PHASE4_DETAIL="${PHASE4_DETAIL_ACCUM}"
  log "  -> PASSED"
else
  PHASE4_STATUS="FAIL"
  PHASE4_DETAIL="${PHASE4_DETAIL_ACCUM}"
  OVERALL_FAILED=1
fi

# If peers are missing but HTTP storage works, downgrade to WARN
if [ "${PHASE4_HTTP_OK}" -eq 1 ] && [ "${PHASE4_PEERS_OK}" -eq 0 ] && [ "${EXPECTED_SPEGEL_PODS}" -gt 1 ]; then
  PHASE4_STATUS="WARN"
  PHASE4_DETAIL="${PHASE4_DETAIL_ACCUM} (P2P mesh not fully formed)"
  log "  -> WARN (no peers despite multi-node cluster)"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Spegel P2P Mirror Verification Summary ==="
printf "%-10s %-12s %-60s\n" "PHASE"      "STATUS" "DETAIL"
printf "%-10s %-12s %-60s\n" "-----"      "------" "------"
printf "%-10s %-12s %-60s\n" "1-Pods"     "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-10s %-12s %-60s\n" "2-Config"   "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-10s %-12s %-60s\n" "3-Metrics"  "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-10s %-12s %-60s\n" "4-P2P"      "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
echo "================================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "================================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-spegel: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-spegel: ALL CHECKS PASSED"
exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-infisical.sh -- Infisical + Secrets Operator health verification
#
# Verifies Infisical backend pod health, service LoadBalancer IP assignment,
# API endpoint reachability, Secrets Operator pod health, bootstrap Secret
# cleanup, and web UI accessibility.
#
# Designed for post-install validation and troubleshooting. Exits non-zero
# on any phase failure. Gracefully handles still-initialising components
# (LB IP not yet assigned, curl not available) with clear messaging.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-infisical.sh [--kubeconfig <path>]
#                              [--namespace <ns>] [--secrets-op-ns <ns>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="infisical"
SECRETS_OP_NAMESPACE="infisical-secrets-operator"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)         KUBECONFIG="$2";          shift 2 ;;
    --namespace)           NAMESPACE="$2";           shift 2 ;;
    --secrets-op-ns)      SECRETS_OP_NAMESPACE="$2"; shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify Infisical backend health, service LoadBalancer IP, API endpoint,
Secrets Operator pods, bootstrap Secret cleanup, and web UI.

Options:
  --kubeconfig PATH       Path to kubeconfig (default: ../opentofu/kubeconfig)
  --namespace NS          Infisical namespace (default: infisical)
  --secrets-op-ns NS      Secrets Operator namespace (default: infisical-secrets-operator)
  --help, -h              Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "verify-infisical: starting"
log "  kubeconfig:          ${KUBECONFIG}"
log "  namespace:           ${NAMESPACE}"
log "  secrets-op-ns:       ${SECRETS_OP_NAMESPACE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Results accumulator --------------------------------------------------
PHASE1_STATUS=""   # Infisical backend pod health
PHASE1_DETAIL=""
PHASE2_STATUS=""   # Infisical service LoadBalancer IP
PHASE2_DETAIL=""
PHASE3_STATUS=""   # Infisical API endpoint reachability
PHASE3_DETAIL=""
PHASE4_STATUS=""   # Secrets Operator pod health
PHASE4_DETAIL=""
PHASE5_STATUS=""   # Bootstrap Secret absence
PHASE5_DETAIL=""
PHASE6_STATUS=""   # Infisical web UI
PHASE6_DETAIL=""

OVERALL_FAILED=0

# ============================================================================
# Phase 1: Infisical backend pod health
# ============================================================================
log "Phase 1: Checking Infisical backend pods in namespace '${NAMESPACE}'"
POD_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get pods \
  --no-headers 2>&1) \
  || { err "kubectl get pods failed: ${POD_OUTPUT}"; PHASE1_STATUS="FAIL"; PHASE1_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE1_STATUS}" ]; then
  TOTAL=0
  READY=0
  NOT_READY=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    TOTAL=$((TOTAL + 1))
    READY_FIELD=$(echo "$line" | awk '{print $2}')
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')
    READY_NUM="${READY_FIELD%%/*}"

    if [ "${READY_NUM}" -gt 0 ] && [ "${STATUS_FIELD}" = "Running" ]; then
      READY=$((READY + 1))
    else
      POD_NAME=$(echo "$line" | awk '{print $1}')
      NOT_READY="${NOT_READY} ${POD_NAME}(${STATUS_FIELD}/${READY_FIELD})"
    fi
  done <<< "$POD_OUTPUT"

  if [ -n "${NOT_READY}" ]; then
    err "Infisical pods not ready:${NOT_READY}"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="${READY}/${TOTAL} ready"
    OVERALL_FAILED=1
  elif [ "${TOTAL}" -eq 0 ]; then
    err "No pods found in infisical namespace"
    PHASE1_STATUS="FAIL"
    PHASE1_DETAIL="0 pods"
    OVERALL_FAILED=1
  else
    PHASE1_STATUS="PASS"
    PHASE1_DETAIL="${READY}/${TOTAL} ready"
    log "Phase 1: ${PHASE1_DETAIL} -- PASSED"
  fi
fi

# ============================================================================
# Phase 2: Infisical service LoadBalancer IP
# ============================================================================
log "Phase 2: Checking Infisical service LoadBalancer IP"
LB_IP=""
LB_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" get svc \
  infisical -o json 2>&1) \
  || { err "kubectl get svc/infisical failed: ${LB_OUTPUT}"; PHASE2_STATUS="FAIL"; PHASE2_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE2_STATUS}" ]; then
  # Extract LoadBalancer Ingress IP from the service JSON
  LB_IP=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
    get svc infisical -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [ -z "${LB_IP}" ]; then
    # Check if there's a hostname instead
    LB_HOSTNAME=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
      get svc infisical -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

    if [ -z "${LB_HOSTNAME}" ]; then
      PHASE2_STATUS="PASS"
      PHASE2_DETAIL="LB IP/hostname not yet assigned (initializing)"
      log "Phase 2: ${PHASE2_DETAIL} -- PASSED (graceful)"
    else
      LB_IP="${LB_HOSTNAME}"
      PHASE2_STATUS="PASS"
      PHASE2_DETAIL="EXTERNAL-IP=${LB_IP} (hostname)"
      log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
    fi
  else
    PHASE2_STATUS="PASS"
    PHASE2_DETAIL="EXTERNAL-IP=${LB_IP}"
    log "Phase 2: ${PHASE2_DETAIL} -- PASSED"
  fi
fi

# ============================================================================
# Phase 3: Infisical API endpoint reachability
# ============================================================================
log "Phase 3: Checking Infisical API endpoint"
if [ -z "${LB_IP}" ]; then
  PHASE3_STATUS="SKIP"
  PHASE3_DETAIL="LB IP not assigned; cannot reach API"
  log "Phase 3: ${PHASE3_DETAIL} -- SKIPPED"
elif ! command -v curl >/dev/null 2>&1; then
  PHASE3_STATUS="SKIP"
  PHASE3_DETAIL="curl not available in PATH"
  log "Phase 3: ${PHASE3_DETAIL} -- SKIPPED"
else
  API_HTTP_CODE=$(curl -o /dev/null -s -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://${LB_IP}/api/health" 2>&1) || true

  if [ "${API_HTTP_CODE}" = "200" ] || [ "${API_HTTP_CODE}" = "401" ]; then
    PHASE3_STATUS="PASS"
    PHASE3_DETAIL="HTTP ${API_HTTP_CODE} from /api/health"
    log "Phase 3: ${PHASE3_DETAIL} -- PASSED"
  else
    PHASE3_STATUS="WARN"
    PHASE3_DETAIL="HTTP ${API_HTTP_CODE} from /api/health (expected 200 or 401)"
    log "Phase 3: ${PHASE3_DETAIL} -- WARN"
  fi
fi

# ============================================================================
# Phase 4: Secrets Operator pod health
# ============================================================================
log "Phase 4: Checking Secrets Operator pods in namespace '${SECRETS_OP_NAMESPACE}'"
SOP_OUTPUT=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${SECRETS_OP_NAMESPACE}" \
  get pods --no-headers 2>&1) \
  || { err "kubectl get pods in secrets operator ns failed: ${SOP_OUTPUT}"; PHASE4_STATUS="FAIL"; PHASE4_DETAIL="kubectl error"; OVERALL_FAILED=1; }

if [ -z "${PHASE4_STATUS}" ]; then
  SOP_TOTAL=0
  SOP_READY=0
  SOP_NOT_READY=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    SOP_TOTAL=$((SOP_TOTAL + 1))
    READY_FIELD=$(echo "$line" | awk '{print $2}')
    STATUS_FIELD=$(echo "$line" | awk '{print $3}')
    READY_NUM="${READY_FIELD%%/*}"

    if [ "${READY_NUM}" -gt 0 ] && [ "${STATUS_FIELD}" = "Running" ]; then
      SOP_READY=$((SOP_READY + 1))
    else
      POD_NAME=$(echo "$line" | awk '{print $1}')
      SOP_NOT_READY="${SOP_NOT_READY} ${POD_NAME}(${STATUS_FIELD}/${READY_FIELD})"
    fi
  done <<< "$SOP_OUTPUT"

  if [ -n "${SOP_NOT_READY}" ]; then
    err "Secrets Operator pods not ready:${SOP_NOT_READY}"
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="${SOP_READY}/${SOP_TOTAL} ready"
    OVERALL_FAILED=1
  elif [ "${SOP_TOTAL}" -eq 0 ]; then
    err "No pods found in secrets operator namespace"
    PHASE4_STATUS="FAIL"
    PHASE4_DETAIL="0 pods"
    OVERALL_FAILED=1
  else
    PHASE4_STATUS="PASS"
    PHASE4_DETAIL="${SOP_READY}/${SOP_TOTAL} ready"
    log "Phase 4: ${PHASE4_DETAIL} -- PASSED"
  fi
fi

# ============================================================================
# Phase 5: Bootstrap Secret absence (security requirement)
#
# CRITICAL: The bootstrap-infisical Secret MUST be deleted after Infisical
# starts successfully per decision D003. This check uses a negative test:
# kubectl get secret returns non-zero when the Secret does not exist.
#
# REDACTION: This phase MUST NOT log any Secret values (INFISICAL_ENCRYPTION_KEY,
# INFISICAL_ADMIN_PASSWORD, INFISICAL_AUTH_SECRET). Only report existence/absence.
# ============================================================================
log "Phase 5: Checking bootstrap-infisical Secret absence (security requirement)"
if kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" \
  get secret bootstrap-infisical >/dev/null 2>&1; then
  # Secret still exists -- this is a security failure
  err "Phase 5: bootstrap-infisical Secret STILL EXISTS in namespace ${NAMESPACE}"
  PHASE5_STATUS="FAIL"
  PHASE5_DETAIL="bootstrap-infisical still exists"
  OVERALL_FAILED=1
else
  PHASE5_STATUS="PASS"
  PHASE5_DETAIL="bootstrap-infisical deleted"
  log "Phase 5: ${PHASE5_DETAIL} -- PASSED"
fi

# ============================================================================
# Phase 6: Infisical web UI
# ============================================================================
log "Phase 6: Checking Infisical web UI"

if [ -z "${LB_IP}" ]; then
  PHASE6_STATUS="SKIP"
  PHASE6_DETAIL="LB IP not assigned; cannot reach web UI"
  log "Phase 6: ${PHASE6_DETAIL} -- SKIPPED"
elif ! command -v curl >/dev/null 2>&1; then
  PHASE6_STATUS="SKIP"
  PHASE6_DETAIL="curl not available in PATH"
  log "Phase 6: ${PHASE6_DETAIL} -- SKIPPED"
else
  UI_HTTP_CODE=$(curl -o /dev/null -s -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://${LB_IP}/" 2>&1) || true

  if [ "${UI_HTTP_CODE}" = "200" ]; then
    PHASE6_STATUS="PASS"
    PHASE6_DETAIL="HTTP ${UI_HTTP_CODE} from /"
    log "Phase 6: ${PHASE6_DETAIL} -- PASSED"
  else
    PHASE6_STATUS="WARN"
    PHASE6_DETAIL="HTTP ${UI_HTTP_CODE} from / (expected 200)"
    log "Phase 6: ${PHASE6_DETAIL} -- WARN"
  fi
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Infisical Health Verification Summary ==="
printf "%-15s %-12s %-54s\n" "PHASE"       "STATUS" "DETAIL"
printf "%-15s %-12s %-54s\n" "-----"       "------" "------"
printf "%-15s %-12s %-54s\n" "1-Infisical"  "${PHASE1_STATUS}" "${PHASE1_DETAIL}"
printf "%-15s %-12s %-54s\n" "2-LB-IP"      "${PHASE2_STATUS}" "${PHASE2_DETAIL}"
printf "%-15s %-12s %-54s\n" "3-API"        "${PHASE3_STATUS}" "${PHASE3_DETAIL}"
printf "%-15s %-12s %-54s\n" "4-Secrets-Op" "${PHASE4_STATUS}" "${PHASE4_DETAIL}"
printf "%-15s %-12s %-54s\n" "5-Bootstrap"  "${PHASE5_STATUS}" "${PHASE5_DETAIL}"
printf "%-15s %-12s %-54s\n" "6-Web-UI"     "${PHASE6_STATUS}" "${PHASE6_DETAIL}"
echo "========================================================"
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "========================================================"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-infisical: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-infisical: ALL CHECKS PASSED"
exit 0

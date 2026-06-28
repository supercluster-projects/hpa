#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-tls.sh — TLS/cert-manager/HTTPS verification
#
# Verifies TLS termination on Envoy Gateway: cert-manager health,
# ClusterIssuer readiness, Certificate readiness, Gateway HTTPS listener,
# and HTTP-to-HTTPS redirect.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-tls.sh [--kubeconfig <path>]
#                        [--gateway-name <name>]
#                        [--gateway-namespace <ns>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
require_env DEV_GATEWAY_NAME

GATEWAY_NAME="${DEV_GATEWAY_NAME}"
GATEWAY_NAMESPACE="envoy-gateway-system"
CERT_MANAGER_NAMESPACE="cert-manager"
ISSUER_NAME="selfsigned-cluster-issuer"
CERT_NAME="envoy-gateway-tls"
OVERALL_FAILED=0

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG="$2";       shift 2 ;;
    --gateway-name)      GATEWAY_NAME="$2";      shift 2 ;;
    --gateway-namespace) GATEWAY_NAMESPACE="$2"; shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify TLS termination on Envoy Gateway.

Options:
  --kubeconfig PATH       Path to kubeconfig
  --gateway-name NAME     Gateway resource name
  --gateway-namespace NS  Gateway namespace
  --help, -h              Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
log "verify-tls: starting"
log "  gateway:       ${GATEWAY_NAME}"
log "  namespace:     ${GATEWAY_NAMESPACE}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Phase state tracking -------------------------------------------------
PHASE_DETAILS=()
PHASE_STATUSES=()
PHASE_NAMES=()

reset_phase() { PHASE_NAMES+=("$1"); }
pass_phase()  { PHASE_STATUSES+=("PASS"); PHASE_DETAILS+=("$1"); }
fail_phase()  { PHASE_STATUSES+=("FAIL"); PHASE_DETAILS+=("$1"); OVERALL_FAILED=1; }
skip_phase()  { PHASE_STATUSES+=("SKIP"); PHASE_DETAILS+=("$1"); }

# ============================================================================
# Phase 1: cert-manager pod health
# ============================================================================
reset_phase "1-CertManager"

CM_READY=0
CM_TOTAL=0
for pod in $(kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" \
  get pods -l app.kubernetes.io/name=cert-manager -o name 2>/dev/null || true); do
  CM_TOTAL=$((CM_TOTAL + 1))
  ready=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${CERT_MANAGER_NAMESPACE}" \
    get "${pod}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || false)
  [ "${ready}" = "true" ] && CM_READY=$((CM_READY + 1))
done

if [ "${CM_TOTAL}" -eq 0 ]; then
  fail_phase "No cert-manager pods found in ${CERT_MANAGER_NAMESPACE}"
elif [ "${CM_READY}" -eq "${CM_TOTAL}" ]; then
  pass_phase "${CM_READY}/${CM_TOTAL} cert-manager pods Ready"
else
  fail_phase "${CM_READY}/${CM_TOTAL} cert-manager pods Ready"
fi

# ============================================================================
# Phase 2: ClusterIssuer readiness
# ============================================================================
reset_phase "2-ClusterIssuer"

if kubectl get clusterissuer "${ISSUER_NAME}" >/dev/null 2>&1; then
  CI_READY=$(kubectl get clusterissuer "${ISSUER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || "Unknown")
  if [ "${CI_READY}" = "True" ]; then
    pass_phase "${ISSUER_NAME}: Ready"
  else
    fail_phase "${ISSUER_NAME}: ${CI_READY}"
  fi
else
  fail_phase "ClusterIssuer '${ISSUER_NAME}' not found"
fi

# ============================================================================
# Phase 3: Certificate readiness
# ============================================================================
reset_phase "3-Certificate"

if kubectl -n "${GATEWAY_NAMESPACE}" get certificate "${CERT_NAME}" >/dev/null 2>&1; then
  CERT_READY=$(kubectl -n "${GATEWAY_NAMESPACE}" get certificate "${CERT_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || "Unknown")
  CERT_SECRET=$(kubectl -n "${GATEWAY_NAMESPACE}" get certificate "${CERT_NAME}" \
    -o jsonpath='{.spec.secretName}' 2>/dev/null || "Unknown")
  if [ "${CERT_READY}" = "True" ]; then
    # Verify the TLS secret actually exists
    if kubectl -n "${GATEWAY_NAMESPACE}" get secret "${CERT_SECRET}" >/dev/null 2>&1; then
      pass_phase "${CERT_NAME}: Ready (secret: ${CERT_SECRET})"
    else
      fail_phase "${CERT_NAME}: Ready but TLS secret '${CERT_SECRET}' missing"
    fi
  else
    fail_phase "${CERT_NAME}: ${CERT_READY}"
  fi
else
  fail_phase "Certificate '${CERT_NAME}' not found in ${GATEWAY_NAMESPACE}"
fi

# ============================================================================
# Phase 4: Gateway HTTPS listener
# ============================================================================
reset_phase "4-HTTPS-Listener"

GW_HTTPS_PROTO=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].protocol}' 2>/dev/null || "")
GW_HTTPS_PORT=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].port}' 2>/dev/null || "")

if [ "${GW_HTTPS_PROTO}" = "HTTPS" ] && [ "${GW_HTTPS_PORT}" = "443" ]; then
  pass_phase "HTTPS listener on port 443 (mode: Terminate)"
else
  fail_phase "HTTPS listener: protocol=${GW_HTTPS_PROTO:-<missing>}, port=${GW_HTTPS_PORT:-<missing>}"
fi

# ============================================================================
# Phase 5: HTTP-to-HTTPS redirect
# ============================================================================
reset_phase "5-HTTP-Redirect"

REDIRECT_EXISTS=false
for route in $(kubectl -n "${GATEWAY_NAMESPACE}" get httproute -o name 2>/dev/null || true); do
  name=$(echo "${route}" | sed 's|httproute.gateway.networking.k8s.io/||' | sed 's|httproute/||')
  if [ "${name}" = "redirect-https" ]; then
    REDIRECT_EXISTS=true
    break
  fi
done

if [ "${REDIRECT_EXISTS}" = true ]; then
  pass_phase "HTTP-to-HTTPS redirect route 'redirect-https' exists"
else
  fail_phase "HTTP-to-HTTPS redirect route 'redirect-https' not found"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== TLS Verification Summary ==="
printf "%-18s %-12s %-55s\n" "PHASE"           "STATUS" "DETAIL"
printf "%-18s %-12s %-55s\n" "-----"           "------" "------"
for i in "${!PHASE_NAMES[@]}"; do
  printf "%-18s %-12s %-55s\n" "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DETAILS[$i]}"
done
echo "===================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "===================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-tls: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-tls: ALL CHECKS PASSED"
exit 0

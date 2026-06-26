#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-security-policy.sh — Deploy Envoy Gateway SecurityPolicy
#
# Applies the SecurityPolicy Kustomize manifest to the cluster. The
# SecurityPolicy configures gRPC external authorization via Casbin's
# ext_authz service (casbin-ext-authz.casbin:9001) at the Gateway level.
#
# The policy passes the Authorization header (Bearer JWT) to the Casbin
# authorizer for validation and forwards Authorization, X-User, X-Role,
# and X-Sub headers to backend workloads. failOpen is false (block traffic
# if auth is unreachable) with a 10s timeout.
#
# Idempotent: safe to re-run on an already-configured cluster (kubectl
# apply is declarative). All logging goes to stderr; the final summary
# goes to stdout.
#
# Usage: ./install-security-policy.sh [--kubeconfig <path>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Internal defaults (script-internal only) -------------------------
SECURITY_POLICY_NAME="hpa-dev-security-policy"
KUSTOMIZE_DIR="gitops-workloads/security/base"
GATEWAY_NAMESPACE="envoy-gateway-system"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)  KUBECONFIG="$2";  shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Envoy Gateway SecurityPolicy on a Kubernetes cluster.

The SecurityPolicy configures external authorization via Casbin gRPC
ext_authz for the hpa-dev-gateway Gateway, sending the Authorization
header to casbin-ext-authz.casbin:9001 for JWT validation.

Options:
  --kubeconfig PATH   Path to kubeconfig (default: ../opentofu/kubeconfig)
  --help, -h          Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Resolve paths relative to PROJECT_ROOT ------------------------------
KUSTOMIZE_ABS="${PROJECT_ROOT}/${KUSTOMIZE_DIR}"

# ---- Preflight Checks -----------------------------------------------------
log "install-security-policy: starting"
log "  kubeconfig:         ${KUBECONFIG}"
log "  security policy:    ${SECURITY_POLICY_NAME}"
log "  namespace:          ${GATEWAY_NAMESPACE}"
log "  kustomize dir:      ${KUSTOMIZE_ABS}"

command -v kubectl >/dev/null 2>&1  || die "kubectl not found in PATH"
command -v kustomize >/dev/null 2>&1 || die "kustomize not found in PATH (try 'kubectl kustomize')"
[ -f "${KUBECONFIG}" ]              || die "kubeconfig not found at ${KUBECONFIG}"
[ -d "${KUSTOMIZE_ABS}" ]           || die "Kustomize directory not found at ${KUSTOMIZE_ABS}"
[ -f "${KUSTOMIZE_ABS}/kustomization.yaml" ] || die "kustomization.yaml not found in ${KUSTOMIZE_ABS}"

# Verify the Gateway namespace exists (should have been created by install-gateway.sh)
if ! kubectl get namespace "${GATEWAY_NAMESPACE}" > /dev/null 2>&1; then
  die "Gateway namespace '${GATEWAY_NAMESPACE}' not found. Run install-gateway.sh first."
fi

# ============================================================================
# Step 1: Apply SecurityPolicy manifests via Kustomize
# ============================================================================
log "Step 1: Applying SecurityPolicy manifests via Kustomize"

if ! kustomize build "${KUSTOMIZE_ABS}" > /dev/null 2>&1; then
  log "  kustomize build via standalone failed, trying kubectl kustomize..."
  if ! kubectl kustomize "${KUSTOMIZE_ABS}" > /dev/null 2>&1; then
    die "Failed to build Kustomize overlay at '${KUSTOMIZE_ABS}'"
  fi
  kubectl kustomize "${KUSTOMIZE_ABS}" | kubectl apply -f - > /dev/null 2>&1 \
    || die "Failed to apply SecurityPolicy manifests"
else
  kustomize build "${KUSTOMIZE_ABS}" | kubectl apply -f - > /dev/null 2>&1 \
    || die "Failed to apply SecurityPolicy manifests"
fi
log "  SecurityPolicy manifests: APPLIED"

# ============================================================================
# Step 2: Verify the SecurityPolicy was accepted
# ============================================================================
log "Step 2: Verifying SecurityPolicy acceptance"

SP_ACCEPTED="False"
for i in $(seq 1 6); do
  SP_ACCEPTED=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "False")
  if [ "${SP_ACCEPTED}" = "True" ]; then
    log "  SecurityPolicy '${SECURITY_POLICY_NAME}' accepted by Envoy Gateway (attempt ${i})"
    break
  fi
  log "  Waiting for SecurityPolicy acceptance (attempt ${i}/6)..."
  sleep 5
done
if [ "${SP_ACCEPTED}" != "True" ]; then
  log "  (non-fatal) SecurityPolicy '${SECURITY_POLICY_NAME}' was not accepted within the polling window"
fi

# ============================================================================
# Step 3: Gather component statuses for summary
# ============================================================================
log "Step 3: Gathering component statuses"

# SecurityPolicy details
SP_NAME=""
SP_GATEWAY=""
SP_AUTH_BACKEND=""
if kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" > /dev/null 2>&1; then
  SP_NAME="${SECURITY_POLICY_NAME}"
  SP_GATEWAY=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
    -o jsonpath='{.spec.targetRefs[0].name}' 2>/dev/null || echo "N/A")

  AUTH_NAME=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
    -o jsonpath='{.spec.extAuth.grpc.backendRefs[0].name}' 2>/dev/null || echo "")
  AUTH_NS=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
    -o jsonpath='{.spec.extAuth.grpc.backendRefs[0].namespace}' 2>/dev/null || echo "")
  AUTH_PORT=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
    -o jsonpath='{.spec.extAuth.grpc.backendRefs[0].port}' 2>/dev/null || echo "")
  if [ -n "${AUTH_NAME}" ]; then
    SP_AUTH_BACKEND="${AUTH_NAME}.${AUTH_NS}:${AUTH_PORT} (gRPC)"
  else
    SP_AUTH_BACKEND="N/A"
  fi
fi

# Fail-open / timeout
SP_FAIL_OPEN=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
  -o jsonpath='{.spec.extAuth.failOpen}' 2>/dev/null || echo "N/A")
SP_TIMEOUT=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
  -o jsonpath='{.spec.extAuth.timeout}' 2>/dev/null || echo "N/A")
SP_HEADERS_EXT=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
  -o jsonpath='{.spec.extAuth.headersToExtAuth}' 2>/dev/null || echo "N/A")
SP_HEADERS_BE=$(kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" \
  -o jsonpath='{.spec.extAuth.headersToBackend}' 2>/dev/null || echo "N/A")

# Gateway acceptor status
GW_ACCEPTED="Unknown"
if kubectl -n "${GATEWAY_NAMESPACE}" get securitypolicy "${SECURITY_POLICY_NAME}" > /dev/null 2>&1; then
  GW_ACCEPTED="${SP_ACCEPTED}"
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== SecurityPolicy Installation Summary ==="
echo "  SecurityPolicy:       ${SP_NAME}"
echo "    namespace:          ${GATEWAY_NAMESPACE}"
echo "    gateway target:     ${SP_GATEWAY}"
echo "    accepted:           ${GW_ACCEPTED}"
echo "    failOpen:           ${SP_FAIL_OPEN}"
echo "    timeout:            ${SP_TIMEOUT}"
echo ""
echo "  External Auth:"
echo "    type:               gRPC"
echo "    backend:            ${SP_AUTH_BACKEND}"
echo "    headers to auth:    ${SP_HEADERS_EXT}"
echo ""
echo "  Headers to backend:"
echo "    ${SP_HEADERS_BE}"
echo ""
echo "  Kustomize:            ${KUSTOMIZE_ABS}"
echo ""
echo "  Prerequisites:"
echo "    Envoy Gateway:      Required (install-gateway.sh)"
echo "    Casbin authorizer:  Required (install-casbin.sh)"
echo ""
echo "==================================="

log "install-security-policy: completed successfully"
exit 0

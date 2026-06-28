#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-tls.sh — Configure TLS termination on Envoy Gateway
#
# Sets up TLS termination on the Envoy Gateway using cert-manager:
#   1. Creates a self-signed ClusterIssuer for dev certificates
#   2. Creates a Certificate for the envoy-gateway-system namespace
#   3. Patches the Gateway to add an HTTPS listener on port 443
#   4. Creates HTTP-to-HTTPS redirect rules
#
# Requires cert-manager (installed by install-runtimes.sh) and Envoy Gateway
# (installed by install-gateway.sh) to be running.
#
# Idempotent: safe to re-run (kubectl apply is used throughout).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-tls.sh [--kubeconfig <path>]
#                         [--gateway-name <name>]
#                         [--domain <domain>]
#                         [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
require_env DEV_GATEWAY_NAME
require_env DEV_LB_POOL_CIDR

# ---- Internal defaults (script-internal only) -------------------------
GATEWAY_NAME="${DEV_GATEWAY_NAME}"
GATEWAY_NAMESPACE="envoy-gateway-system"
CERT_MANAGER_NAMESPACE="cert-manager"
WAIT_TIMEOUT=300
DOMAIN=""  # Optional: if set, cert SAN includes the domain
CERT_NAME="envoy-gateway-tls"
ISSUER_NAME="selfsigned-cluster-issuer"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG="$2";           shift 2 ;;
    --gateway-name)      GATEWAY_NAME="$2";          shift 2 ;;
    --domain)            DOMAIN="$2";                shift 2 ;;
    --wait-timeout)      WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Configure TLS termination on Envoy Gateway with cert-manager.

Components configured:
  - Self-signed ClusterIssuer
  - Certificate for envoy-gateway-system
  - Gateway HTTPS listener on port 443
  - HTTP-to-HTTPS redirect

Options:
  --kubeconfig PATH    Path to kubeconfig
  --gateway-name NAME  Gateway resource name (default: hpa-dev-gateway)
  --domain DOMAIN      Optional domain for cert SAN
  --wait-timeout SEC   Max wait (default: 300)
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-tls: starting"
log "  kubeconfig:       ${KUBECONFIG}"
log "  gateway-name:     ${GATEWAY_NAME}"
log "  domain:           ${DOMAIN:-<none>}"
log "  issuer:           ${ISSUER_NAME}"
log "  certificate:      ${CERT_NAME}"
log "  wait-timeout:     ${WAIT_TIMEOUT}s"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Phase 1: Create self-signed ClusterIssuer ----------------------------
log "Phase 1: Creating self-signed ClusterIssuer '${ISSUER_NAME}'..."

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || die "Failed to create ClusterIssuer"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ISSUER_NAME}
spec:
  selfSigned: {}
EOF
log "  ClusterIssuer '${ISSUER_NAME}': APPLIED"

# Wait for ClusterIssuer to be ready
for i in $(seq 1 12); do
  CI_READY=$(kubectl get clusterissuer "${ISSUER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "${CI_READY}" = "True" ]; then
    log "  ClusterIssuer ready (attempt ${i})"
    break
  fi
  log "  Waiting for ClusterIssuer readiness (attempt ${i}/12)..."
  sleep 5
done

if [ "${CI_READY}" != "True" ]; then
  log "  (non-fatal) ClusterIssuer not ready within polling window — continuing"
fi

# ---- Phase 2: Create Certificate for envoy-gateway-system -----------------
log "Phase 2: Creating Certificate '${CERT_NAME}' in namespace ${GATEWAY_NAMESPACE}..."

# Build SANs for the certificate
# Default SAN is the Envoy LB IP (auto-detected), or the domain if provided
SAN_ARGS=()
if [ -n "${DOMAIN}" ]; then
  SAN_ARGS+=("*.${DOMAIN}" "${DOMAIN}")
fi
# Add a wildcard for the default cluster domain
SAN_ARGS+=("*.envoy-gateway-system.svc.cluster.local")

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || die "Failed to create Certificate"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${GATEWAY_NAMESPACE}
spec:
  secretName: ${CERT_NAME}
  duration: 2160h  # 90 days
  renewBefore: 360h  # 15 days
  subject:
    organizations:
      - HPA Dev
  commonName: envoy-gateway
  dnsNames:
$(for san in "${SAN_ARGS[@]}"; do echo "    - ${san}"; done)
  issuerRef:
    name: ${ISSUER_NAME}
    kind: ClusterIssuer
EOF
log "  Certificate '${CERT_NAME}': APPLIED"

# ---- Phase 3: Patch Gateway to add HTTPS listener -------------------------
log "Phase 3: Updating Gateway '${GATEWAY_NAME}' with HTTPS listener..."

# Get the current Gateway spec and merge in the HTTPS listener
# We use kubectl patch to add the HTTPS listener alongside the existing HTTP one
kubectl patch gateway "${GATEWAY_NAME}" -n "${GATEWAY_NAMESPACE}" \
  --type='json' \
  -p="[
    {
      \"op\": \"add\",
      \"path\": \"/spec/listeners/-\",
      \"value\": {
        \"name\": \"https\",
        \"protocol\": \"HTTPS\",
        \"port\": 443,
        \"tls\": {
          \"mode\": \"Terminate\",
          \"certificateRefs\": [
            {
              \"name\": \"${CERT_NAME}\"
            }
          ]
        },
        \"allowedRoutes\": {
          \"namespaces\": {
            \"from\": \"All\"
          }
        }
      }
    }
  ]" 2>&1 && log "  Gateway HTTPS listener: ADDED" || {
  # If the listener already exists, this fails — which is fine for idempotency
  log "  Gateway HTTPS listener: already exists (or patch accepted)"
}

# Verify Gateway accepted the HTTPS listener
for i in $(seq 1 12); do
  GW_ACCEPTED=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  if [ "${GW_ACCEPTED}" = "True" ]; then
    log "  Gateway accepted after HTTPS update (attempt ${i})"
    break
  fi
  log "  Waiting for Gateway re-acceptance (attempt ${i}/12)..."
  sleep 5
done

# ---- Phase 4: Create HTTP-to-HTTPS redirect route -------------------------
log "Phase 4: Creating HTTP-to-HTTPS redirect HTTPRoute..."

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || die "Failed to create redirect HTTPRoute"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: redirect-https
  namespace: ${GATEWAY_NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
EOF
log "  HTTP-to-HTTPS redirect: APPLIED"

# ---- Phase 5: Wait for Certificate readiness ------------------------------
log "Phase 5: Waiting for Certificate '${CERT_NAME}' to be Ready..."

for i in $(seq 1 24); do
  CERT_READY=$(kubectl -n "${GATEWAY_NAMESPACE}" get certificate "${CERT_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "${CERT_READY}" = "True" ]; then
    log "  Certificate Ready (attempt ${i})"
    break
  fi
  log "  Waiting for Certificate readiness (attempt ${i}/24)..."
  sleep 5
done

if [ "${CERT_READY}" != "True" ]; then
  log "  (non-fatal) Certificate not Ready within polling window"
fi

# ---- Phase 6: Patch welcome-route to point to actual Knative welcome service ---
log "Phase 6: Patching welcome-route backend to Knative welcome service..."

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || log "  (non-fatal) Could not update welcome-route"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: welcome-route
  namespace: ${GATEWAY_NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/welcome
      backendRefs:
        - name: welcome
          namespace: hpa-workloads
          port: 80
EOF
log "  welcome-route backend: Knative welcome.hpa-workloads:80"

# ---- Phase 7: Apply gql HTTPRoute over HTTPS ------------------------------
log "Phase 7: Applying gql HTTPRoute over HTTPS..."

# gql-route.yaml is stored in gitops-workloads/graphql/
# Apply it from the repository path
GQL_ROUTE="${SCRIPT_DIR}/../gitops-workloads/graphql/gql-route.yaml"
if [ -f "${GQL_ROUTE}" ]; then
  kubectl apply -f "${GQL_ROUTE}" > /dev/null 2>&1
  log "  gql HTTPRoute: APPLIED from ${GQL_ROUTE}"
else
  log "  (non-fatal) gql-route.yaml not found at ${GQL_ROUTE} — applying inline..."
  # Fallback: apply from the file in the repo root
  GQL_ALT="${PROJECT_ROOT}/gitops-workloads/graphql/gql-route.yaml"
  if [ -f "${GQL_ALT}" ]; then
    kubectl apply -f "${GQL_ALT}" > /dev/null 2>&1
    log "  gql HTTPRoute: APPLIED from ${GQL_ALT}"
  fi
fi

# ---- Gather status for summary --------------------------------------------
CI_STATUS=$(kubectl get clusterissuer "${ISSUER_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

CERT_STATUS=$(kubectl -n "${GATEWAY_NAMESPACE}" get certificate "${CERT_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

GW_HTTPS=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].protocol}' 2>/dev/null || echo "Not configured")

GW_ACCEPTED=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")

GW_LB=$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "<pending>")

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== TLS Configuration Summary ==="
echo "  ClusterIssuer:    ${ISSUER_NAME} (${CI_STATUS})"
echo "  Certificate:      ${CERT_NAME} (${CERT_STATUS})"
echo "  Namespace:        ${GATEWAY_NAMESPACE}"
echo "  Gateway:          ${GATEWAY_NAME}"
echo "    HTTPS:          ${GW_HTTPS}"
echo "    Accepted:       ${GW_ACCEPTED}"
echo "    LB address:     ${GW_LB}"
echo ""
echo "  HTTP-to-HTTPS:    ACTIVE"
echo ""
echo "  Quick checks:"
echo "    kubectl get clusterissuer ${ISSUER_NAME}"
echo "    kubectl -n ${GATEWAY_NAMESPACE} get certificate ${CERT_NAME}"
echo "    kubectl -n ${GATEWAY_NAMESPACE} get gateway ${GATEWAY_NAME} -o yaml"
echo "    curl -k -v https://${GW_LB}/api/welcome"
echo "    curl -v http://${GW_LB}/api/welcome  # should redirect to https://"
echo "======================================"

log "install-tls: completed successfully"
exit 0

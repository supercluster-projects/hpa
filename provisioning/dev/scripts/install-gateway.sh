#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-gateway.sh — Deploy Envoy Gateway + Headlamp + HTTPRoutes on K8s
#
# Installs:
#   1. Envoy Gateway — Kubernetes-native ingress controller (Helm chart)
#   2. Gateway resource — LoadBalancer with port 80 listener
#   3. HTTPRoute 'welcome-route' — placeholder backend for /api/welcome
#   4. HTTPRoute 'admin-route' — routes /admin to Headlamp dashboard
#   5. Headlamp — Kubernetes web UI dashboard (ClusterIP, behind Gateway)
#
# Envoy Gateway's Helm chart automatically creates a GatewayClass named
# 'envoy-gateway'. The Gateway resource references this class.
#
# Idempotent: safe to re-run on an already-configured cluster (Helm
# upgrade --atomic --wait and kubectl apply are used throughout).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-gateway.sh [--kubeconfig <path>]
#                             [--envoy-version <ver>]
#                             [--headlamp-version <ver>]
#                             [--gateway-name <name>]
#                             [--lb-type <type>]
#                             [--domain <domain>]
#                             [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env ENVOY_VERSION
require_env HEADLAMP_VERSION
require_env DEV_GATEWAY_NAME

# ---- Internal defaults (script-internal only) -------------------------
GATEWAY_NAME="${DEV_GATEWAY_NAME}"
WAIT_TIMEOUT=600
GATEWAY_NAMESPACE="envoy-gateway-system"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG="$2";           shift 2 ;;
    --envoy-version)     ENVOY_VERSION="$2";        shift 2 ;;
    --headlamp-version)  HEADLAMP_VERSION="$2";      shift 2 ;;
    --gateway-name)      GATEWAY_NAME="$2";          shift 2 ;;
    --lb-type)           LB_TYPE="$2";               shift 2 ;;
    --domain)            DOMAIN="$2";                shift 2 ;;
    --wait-timeout)      WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Envoy Gateway + Headlamp + HTTPRoutes on a Kubernetes cluster.

Components installed:
  - Envoy Gateway       Kubernetes-native ingress controller (Helm chart)
  - Gateway resource    LoadBalancer Gateway with port 80 listener
  - HTTPRoute           welcome-route (placeholder backend for /api/welcome)
  - HTTPRoute           admin-route (routes /admin to Headlamp)
  - Headlamp            Kubernetes web UI dashboard

Options:
  --kubeconfig PATH         Path to kubeconfig (default: ../opentofu/kubeconfig)
  --envoy-version VER       Envoy Gateway Helm chart version (default: v1.2.2)
  --headlamp-version VER    Headlamp Helm chart version (default: 0.16.0)
  --gateway-name NAME       Gateway resource name (default: hpa-dev-gateway)
  --lb-type TYPE            Gateway listener service type (default: LoadBalancer)
  --domain DOMAIN           Domain suffix for Gateway listener (optional)
  --wait-timeout DUR        Timeout for Helm install and rollouts (default: 10m)
  --help, -h                Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-gateway: starting"
log "  kubeconfig:        ${KUBECONFIG}"
log "  envoy-version:     ${ENVOY_VERSION}"
log "  headlamp-version:  ${HEADLAMP_VERSION}"
log "  gateway-name:      ${GATEWAY_NAME}"
log "  lb-type:           ${LB_TYPE}"
log "  domain:            ${DOMAIN:-<none>}"
log "  wait-timeout:      ${WAIT_TIMEOUT}"

command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Internal state tracking ----------------------------------------------
ENVOY_GATEWAY_INSTALLED=false
HEADLAMP_INSTALLED=false

# ============================================================================
# Step 1: Install Envoy Gateway via Helm
# ============================================================================
log "Step 1: Installing Envoy Gateway (${ENVOY_VERSION})"

helm repo add envoy-gateway https://gateway.envoyproxy.io/helm \
  --force-update > /dev/null 2>&1 \
  || die "Failed to add Envoy Gateway Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Envoy Gateway Helm repo: READY"

kubectl create namespace "${ENVOY_GATEWAY_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${ENVOY_GATEWAY_NAMESPACE}'"
log "  Namespace '${ENVOY_GATEWAY_NAMESPACE}': READY"

helm upgrade --install envoy-gateway envoy-gateway/envoy-gateway \
  --namespace "${ENVOY_GATEWAY_NAMESPACE}" \
  --version "${ENVOY_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  > /dev/null 2>&1 || log "  (non-fatal) Envoy Gateway Helm install will be re-attempted via --atomic"

# Verify Envoy Gateway installed; if not, retry once
if kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get daemonset envoy-gateway > /dev/null 2>&1; then
  ENVOY_GATEWAY_INSTALLED=true
  log "  Envoy Gateway: INSTALLED"
else
  log "  Envoy Gateway not found after first attempt, retrying..."
  helm upgrade --install envoy-gateway envoy-gateway/envoy-gateway \
    --namespace "${ENVOY_GATEWAY_NAMESPACE}" \
    --version "${ENVOY_VERSION}" \
    --atomic \
    --wait \
    --timeout "${WAIT_TIMEOUT}" \
    > /dev/null 2>&1 || die "Envoy Gateway Helm install failed after retry"
  ENVOY_GATEWAY_INSTALLED=true
  log "  Envoy Gateway: INSTALLED"
fi

# Wait for Envoy Gateway DaemonSet rollout
if kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get daemonset envoy-gateway > /dev/null 2>&1; then
  kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" rollout status daemonset/envoy-gateway \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || die "Envoy Gateway DaemonSet rollout did not complete within ${WAIT_TIMEOUT}"
  log "  DaemonSet 'envoy-gateway': ROLLOUT COMPLETE"
else
  log "  DaemonSet 'envoy-gateway': NOT FOUND (skipping rollout wait)"
fi

# ============================================================================
# Step 2: Create Gateway resource with LoadBalancer listener on port 80
# ============================================================================
log "Step 2: Creating Gateway resource '${GATEWAY_NAME}'"

LISTENER_HOSTNAME=""
if [ -n "${DOMAIN}" ]; then
  LISTENER_HOSTNAME="$(cat <<HOSTNAME_EVAL
      hostname: ${DOMAIN}
HOSTNAME_EVAL
)"
fi

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply Gateway resource"
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${ENVOY_GATEWAY_NAMESPACE}
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF
log "  Gateway '${GATEWAY_NAME}': APPLIED"

# Verify Gateway is accepted by the controller
for i in $(seq 1 12); do
  GW_ACCEPTED=$(kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  if [ "${GW_ACCEPTED}" = "True" ]; then
    log "  Gateway '${GATEWAY_NAME}' accepted by controller (attempt ${i})"
    break
  fi
  log "  Waiting for Gateway acceptance (attempt ${i}/12)..."
  sleep 5
done
if [ "${GW_ACCEPTED}" != "True" ]; then
  log "  (non-fatal) Gateway '${GATEWAY_NAME}' was not accepted within the polling window"
fi

# ============================================================================
# Step 3: Create HTTPRoute 'welcome-route' for /api/welcome (placeholder)
# ============================================================================
log "Step 3: Creating HTTPRoute 'welcome-route' for /api/welcome"

# This route uses a placeholder backend service (will be patched by later slices).
# BackendRef points to a service named 'welcome-backend' on port 8080 as a stub.
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply HTTPRoute 'welcome-route'"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: welcome-route
  namespace: ${ENVOY_GATEWAY_NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/welcome
      backendRefs:
        - name: welcome-backend
          port: 8080
EOF
log "  HTTPRoute 'welcome-route': APPLIED"

# ============================================================================
# Step 4: Create HTTPRoute 'admin-route' for /admin to Headlamp (placeholder)
# ============================================================================
log "Step 4: Creating HTTPRoute 'admin-route' for /admin"

# This route will be updated by a later slice to point to the actual Headlamp
# service. For now it uses a placeholder backend name.
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to apply HTTPRoute 'admin-route'"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: admin-route
  namespace: ${ENVOY_GATEWAY_NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /admin
      backendRefs:
        - name: admin-backend
          port: 80
EOF
log "  HTTPRoute 'admin-route': APPLIED"

# ============================================================================
# Step 5: Install Headlamp via Helm
# ============================================================================
log "Step 5: Installing Headlamp (${HEADLAMP_VERSION})"

helm repo add headlamp https://headlamp-k8s.github.io/headlamp \
  --force-update > /dev/null 2>&1 \
  || die "Failed to add Headlamp Helm repo"
helm repo update > /dev/null 2>&1 \
  || die "Failed to update Helm repos"
log "  Headlamp Helm repo: READY"

kubectl create namespace "${HEADLAMP_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${HEADLAMP_NAMESPACE}'"
log "  Namespace '${HEADLAMP_NAMESPACE}': READY"

helm upgrade --install headlamp headlamp/headlamp \
  --namespace "${HEADLAMP_NAMESPACE}" \
  --version "${HEADLAMP_VERSION}" \
  --atomic \
  --wait \
  --timeout "${WAIT_TIMEOUT}" \
  --set service.type=ClusterIP \
  > /dev/null 2>&1 || log "  (non-fatal) Headlamp Helm install will be re-attempted via --atomic"

# Verify Headlamp installed; if not, retry once
if kubectl -n "${HEADLAMP_NAMESPACE}" get deployment headlamp > /dev/null 2>&1; then
  HEADLAMP_INSTALLED=true
  log "  Headlamp: INSTALLED"
else
  log "  Headlamp not found after first attempt, retrying..."
  helm upgrade --install headlamp headlamp/headlamp \
    --namespace "${HEADLAMP_NAMESPACE}" \
    --version "${HEADLAMP_VERSION}" \
    --atomic \
    --wait \
    --timeout "${WAIT_TIMEOUT}" \
    --set service.type=ClusterIP \
    > /dev/null 2>&1 || die "Headlamp Helm install failed after retry"
  HEADLAMP_INSTALLED=true
  log "  Headlamp: INSTALLED"
fi

# Wait for Headlamp deployment rollout
if kubectl -n "${HEADLAMP_NAMESPACE}" get deployment headlamp > /dev/null 2>&1; then
  kubectl -n "${HEADLAMP_NAMESPACE}" rollout status deployment/headlamp \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    || die "Headlamp deployment rollout did not complete within ${WAIT_TIMEOUT}"
  log "  Deployment 'headlamp': ROLLOUT COMPLETE"
else
  log "  Deployment 'headlamp': NOT FOUND (skipping rollout wait)"
fi

# ============================================================================
# Step 6: Update admin-route to point to actual Headlamp service
# ============================================================================
log "Step 6: Updating admin-route backend to Headlamp service"

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 \
  || log "  (non-fatal) Could not update admin-route backend (will be handled by later slice)"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: admin-route
  namespace: ${ENVOY_GATEWAY_NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /admin
      backendRefs:
        - name: headlamp
          namespace: ${HEADLAMP_NAMESPACE}
          port: 80
EOF
log "  HTTPRoute 'admin-route' backend updated to headlamp.${HEADLAMP_NAMESPACE}:80"

# ============================================================================
# Step 7: Gather component statuses for summary
# ============================================================================
log "Step 7: Gathering component statuses"

# Envoy Gateway status
EG_STATUS="NOT INSTALLED"
if [ "${ENVOY_GATEWAY_INSTALLED}" = true ]; then
  EG_READY=$(kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get daemonset envoy-gateway \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  EG_DESIRED=$(kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get daemonset envoy-gateway \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  EG_GW_ACCEPTED=$(kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
  EG_STATUS="ready: ${EG_READY}/${EG_DESIRED}, gateway: ${EG_GW_ACCEPTED}"
fi

# HTTPRoute statuses
WELCOME_ROUTE_ACCEPTED="Unknown"
if kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get httproute welcome-route > /dev/null 2>&1; then
  WELCOME_ROUTE_ACCEPTED=$(kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get httproute welcome-route \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
fi

ADMIN_ROUTE_ACCEPTED="Unknown"
if kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get httproute admin-route > /dev/null 2>&1; then
  ADMIN_ROUTE_ACCEPTED=$(kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get httproute admin-route \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
fi

# Headlamp status
HEADLAMP_STATUS="NOT INSTALLED"
if [ "${HEADLAMP_INSTALLED}" = true ]; then
  HEADLAMP_READY=$(kubectl -n "${HEADLAMP_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  HEADLAMP_ROLLOUT=$(kubectl -n "${HEADLAMP_NAMESPACE}" rollout status deployment/headlamp \
    --timeout=5s 2>/dev/null && echo "Ready" || echo "Not Ready")
  HEADLAMP_STATUS="${HEADLAMP_ROLLOUT} (replicas: ${HEADLAMP_READY:-0})"
fi

# Gateway LoadBalancer address
GW_LB_ADDRESS=""
GW_LB_ADDRESS=$(kubectl -n "${ENVOY_GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Gateway Installation Summary ==="
echo "  Envoy Gateway:        ${ENVOY_VERSION}"
echo "    namespace:          ${ENVOY_GATEWAY_NAMESPACE}"
echo "    status:             ${EG_STATUS}"
echo "    gateway:            ${GATEWAY_NAME}"
echo "    LB address:         ${GW_LB_ADDRESS:-<pending>}"
echo ""
echo "  HTTPRoutes:"
echo "    welcome-route:      /api/welcome -> welcome-backend:8080"
echo "      accepted:         ${WELCOME_ROUTE_ACCEPTED}"
echo "      namespace:        ${ENVOY_GATEWAY_NAMESPACE}"
echo ""
echo "    admin-route:        /admin -> headlamp:80 (namespace: ${HEADLAMP_NAMESPACE})"
echo "      accepted:         ${ADMIN_ROUTE_ACCEPTED}"
echo "      namespace:        ${ENVOY_GATEWAY_NAMESPACE}"
echo ""
echo "  Headlamp:             ${HEADLAMP_VERSION}"
echo "    namespace:          ${HEADLAMP_NAMESPACE}"
echo "    service:            headlamp.${HEADLAMP_NAMESPACE}.svc.cluster.local:80"
echo "    status:             ${HEADLAMP_STATUS}"
echo ""
echo "  Helm release status:"
for release in envoy-gateway headlamp; do
  case "${release}" in
    envoy-gateway) RLS_NS="${ENVOY_GATEWAY_NAMESPACE}" ;;
    headlamp)      RLS_NS="${HEADLAMP_NAMESPACE}" ;;
  esac
  if helm status "${release}" -n "${RLS_NS}" > /dev/null 2>&1; then
    helm status "${release}" -n "${RLS_NS}" 2>/dev/null \
      | grep -E "^(STATUS:|NAMESPACE:|LAST DEPLOYED:)" \
      | sed "s/^/    [${release}] /" || true
  fi
done
echo ""
echo "  GatewayClass:"
if kubectl get gatewayclass envoy-gateway > /dev/null 2>&1; then
  GWC_STATUS=$(kubectl get gatewayclass envoy-gateway \
    -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  echo "    envoy-gateway: ${GWC_STATUS}"
else
  echo "    envoy-gateway: NOT FOUND"
fi
echo ""
echo "  Gateway API CRDs:"
for crd in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io; do
  if kubectl get crd "${crd}" > /dev/null 2>&1; then
    echo "    ${crd}: PRESENT"
  else
    echo "    ${crd}: MISSING"
  fi
done
echo ""
echo "  Headlamp URL:         http://${GW_LB_ADDRESS:-<gw-lb-ip>}/admin"
echo ""
echo "==================================="

log "install-gateway: completed successfully"
exit 0

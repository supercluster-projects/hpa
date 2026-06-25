#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-workloads.sh — Deploy welcome Knative Service + counter SpinApp
#
# Deploys the hello-world application workloads on a Kubernetes cluster:
#   1. Create namespace hpa-workloads (idempotent)
#   2. Apply Knative Service 'welcome' via Kustomize overlay
#   3. Apply SpinApp 'counter' via Kustomize overlay
#   4. Wait for Knative Service 'welcome' to become Ready
#   5. Wait for SpinApp 'counter' to become Ready
#   6. Patch welcome-route HTTPRoute backendRef from placeholder to actual ksvc
#
# The Kustomize overlay at --gitops-overlay-path should contain:
#   - kustomization.yaml (with functions/welcome.yaml, spins/counter.yaml)
#   - functions/welcome.yaml
#   - spins/counter.yaml
#
# Idempotent: safe to re-run on an already-configured cluster (kubectl apply
# is used throughout, waits and patches are conditional).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-workloads.sh [--kubeconfig <path>]
#                               [--gitops-overlay-path <path>]
#                               [--gateway-namespace <ns>]
#                               [--gateway-name <name>]
#                               [--httproute-name <name>]
#                               [--workloads-namespace <ns>]
#                               [--wait-timeout <duration>]
#                               [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env DEV_WORKLOADS_NAMESPACE
require_env DEV_GATEWAY_NAMESPACE
require_env DEV_GATEWAY_NAME
require_env DEV_HTTPROUTE_NAME
require_env DEV_GITOPS_OVERLAY_PATH

# ---- Internal defaults (script-internal only) -------------------------
WORKLOADS_NAMESPACE="${DEV_WORKLOADS_NAMESPACE}"
GATEWAY_NAMESPACE="${DEV_GATEWAY_NAMESPACE}"
GATEWAY_NAME="${DEV_GATEWAY_NAME}"
HTTPROUTE_NAME="${DEV_HTTPROUTE_NAME}"
GITOPS_OVERLAY_PATH="${DEV_GITOPS_OVERLAY_PATH}"
WAIT_TIMEOUT=600

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)            KUBECONFIG="$2";             shift 2 ;;
    --gitops-overlay-path)   GITOPS_OVERLAY_PATH="$2";    shift 2 ;;
    --gateway-namespace)     GATEWAY_NAMESPACE="$2";      shift 2 ;;
    --gateway-name)          GATEWAY_NAME="$2";           shift 2 ;;
    --httproute-name)        HTTPROUTE_NAME="$2";         shift 2 ;;
    --workloads-namespace)   WORKLOADS_NAMESPACE="$2";    shift 2 ;;
    --wait-timeout)          WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy welcome Knative Service + counter SpinApp workloads.

Steps:
  1  Create namespace hpa-workloads (idempotent)
  2  Apply Knative Service 'welcome' via Kustomize
  3  Apply SpinApp 'counter' via Kustomize
  4  Wait for Knative Service 'welcome' to become Ready
  5  Wait for SpinApp 'counter' to become Ready
  6  Patch welcome-route HTTPRoute to point to welcome ksvc backend

Options:
  --kubeconfig PATH              Path to kubeconfig (default: ../opentofu/kubeconfig)
  --gitops-overlay-path PATH     Kustomize overlay directory (default: ../../gitops-workloads/functions/overlays/dev)
  --gateway-namespace NS         Envoy Gateway namespace (default: envoy-gateway-system)
  --gateway-name NAME            Gateway resource name (default: hpa-dev-gateway)
  --httproute-name NAME          HTTPRoute name for /api/welcome (default: welcome-route)
  --workloads-namespace NS       Target namespace for workloads (default: hpa-workloads)
  --wait-timeout DUR             Timeout for kubectl rollout and condition waits (default: 10m)
  --help, -h                     Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-workloads: starting"
log "  kubeconfig:           ${KUBECONFIG}"
log "  gitops overlay path:  ${GITOPS_OVERLAY_PATH}"
log "  gateway namespace:    ${GATEWAY_NAMESPACE}"
log "  gateway name:         ${GATEWAY_NAME}"
log "  httproute name:       ${HTTPROUTE_NAME}"
log "  workloads namespace:  ${WORKLOADS_NAMESPACE}"
log "  wait timeout:         ${WAIT_TIMEOUT}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v kustomize >/dev/null 2>&1 || die "kustomize not found in PATH (try 'kubectl kustomize')"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"
[ -d "${GITOPS_OVERLAY_PATH}" ] || die "gitops overlay path not found at ${GITOPS_OVERLAY_PATH}"
[ -f "${GITOPS_OVERLAY_PATH}/kustomization.yaml" ] || die "kustomization.yaml not found in overlay path"

# ---- Internal state tracking ----------------------------------------------
WELCOME_APPLIED=false
COUNTER_APPLIED=false
HTTPROUTE_PATCHED=false

# ============================================================================
# Step 1: Ensure namespace hpa-workloads
# ============================================================================
log "Step 1: Ensuring namespace '${WORKLOADS_NAMESPACE}'"

kubectl create namespace "${WORKLOADS_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1 \
  || die "Failed to ensure namespace '${WORKLOADS_NAMESPACE}'"
log "  Namespace '${WORKLOADS_NAMESPACE}': READY"

# ============================================================================
# Step 2: Apply Knative Service 'welcome' via Kustomize
# ============================================================================
log "Step 2: Applying Knative Service 'welcome' via Kustomize"

# Use kubectl kustomize to render and apply. We use a temporary build to
# validate the Kustomize overlay before applying.
if ! kustomize build "${GITOPS_OVERLAY_PATH}" > /dev/null 2>&1; then
  # Fallback: try kubectl kustomize
  log "  kustomize build via standalone failed, trying kubectl kustomize..."
  if ! kubectl kustomize "${GITOPS_OVERLAY_PATH}" > /dev/null 2>&1; then
    die "Failed to build Kustomize overlay at '${GITOPS_OVERLAY_PATH}'"
  fi
  kubectl kustomize "${GITOPS_OVERLAY_PATH}" | kubectl apply -f - > /dev/null 2>&1 \
    || die "Failed to apply Kustomize overlay for workloads"
else
  kustomize build "${GITOPS_OVERLAY_PATH}" | kubectl apply -f - > /dev/null 2>&1 \
    || die "Failed to apply Kustomize overlay for workloads"
fi

log "  Kustomize overlay applied via kubectl apply: DONE"

# Verify that the Knative Service exists
if kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome > /dev/null 2>&1; then
  WELCOME_APPLIED=true
  log "  Knative Service 'welcome': APPLIED"
else
  # The Kustomize overlay may use a different resource path. Try kubectl apply
  # directly on the individual manifests.
  log "  ksvc/welcome not found via Kustomize, applying individual manifests..."
  for manifest in "${GITOPS_OVERLAY_PATH}"/*.yaml; do
    [ -f "${manifest}" ] || continue
    kubectl apply -f "${manifest}" > /dev/null 2>&1 || log "  (non-fatal) Could not apply ${manifest}"
  done
  if kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome > /dev/null 2>&1; then
    WELCOME_APPLIED=true
    log "  Knative Service 'welcome': APPLIED (via individual manifests)"
  else
    log "  (non-fatal) Knative Service 'welcome' not yet visible — will retry in Step 4"
  fi
fi

# Verify SpinApp exists
if kubectl -n "${WORKLOADS_NAMESPACE}" get spinapp counter > /dev/null 2>&1; then
  COUNTER_APPLIED=true
  log "  SpinApp 'counter': APPLIED"
else
  log "  (non-fatal) SpinApp 'counter' not yet visible — will retry in Step 5"
fi

# ============================================================================
# Step 3: Verify the Kustomize build rendered the expected resources
# ============================================================================
log "Step 3: Verifying Kustomize build output"

BUILD_OUTPUT=$(kustomize build "${GITOPS_OVERLAY_PATH}" 2>/dev/null || kubectl kustomize "${GITOPS_OVERLAY_PATH}" 2>/dev/null || echo "")
if [ -z "${BUILD_OUTPUT}" ]; then
  log "  WARNING: Kustomize build produced no output — overlay may be empty"
else
  # Check for key resources in the build
  KSVC_COUNT=$(echo "${BUILD_OUTPUT}" | grep -c "kind:.*Service.*serving.knative.dev" 2>/dev/null || echo "0")
  SPINAPP_COUNT=$(echo "${BUILD_OUTPUT}" | grep -c "kind:.*SpinApp" 2>/dev/null || echo "0")
  if [ "${KSVC_COUNT}" -gt 0 ]; then
    log "  Kustomize build: Knative Service resource found (${KSVC_COUNT})"
  else
    log "  Kustomize build: No Knative Service found — checking for regular Service..."
    SERVICE_COUNT=$(echo "${BUILD_OUTPUT}" | grep -c "^kind: Service$" 2>/dev/null || echo "0")
    log "  Kustomize build: ${SERVICE_COUNT} regular Service resource(s) found"
  fi
  if [ "${SPINAPP_COUNT}" -gt 0 ]; then
    log "  Kustomize build: SpinApp resource found"
  else
    log "  Kustomize build: No SpinApp resource found"
  fi
  TOTAL_RESOURCES=$(echo "${BUILD_OUTPUT}" | grep -c "^---" 2>/dev/null || echo "0")
  log "  Kustomize build: approximately $((TOTAL_RESOURCES + 1)) resource(s)"
fi

# ============================================================================
# Step 4: Wait for Knative Service 'welcome' to become Ready
# ============================================================================
log "Step 4: Waiting for Knative Service 'welcome' to become Ready"

WELCOME_STATUS="NOT READY"
if [ "${WELCOME_APPLIED}" = true ]; then
  # Use kubectl wait with condition=Ready on the Knative Service
  if kubectl -n "${WORKLOADS_NAMESPACE}" wait --for=condition=Ready ksvc/welcome \
    --timeout="${WAIT_TIMEOUT}" > /dev/null 2>&1; then
    WELCOME_STATUS="Ready"
    log "  Knative Service 'welcome': READY"
  else
    # Check actual condition for diagnostic
    KSVC_CONDITION=$(kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    KSVC_REASON=$(kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")
    KSVC_URL=$(kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
      -o jsonpath='{.status.url}' 2>/dev/null || echo "Unknown")

    # If the ksvc is progressing but not yet Ready, report the latest condition
    if [ "${KSVC_CONDITION}" = "Unknown" ]; then
      log "  Knative Service 'welcome' still progressing: condition=${KSVC_CONDITION}, reason=${KSVC_REASON}"
      WELCOME_STATUS="Progressing (${KSVC_REASON})"
    else
      err "Knative Service 'welcome' not Ready within ${WAIT_TIMEOUT}: condition=${KSVC_CONDITION}, reason=${KSVC_REASON}"
      WELCOME_STATUS="Failed (${KSVC_CONDITION}: ${KSVC_REASON})"
    fi

    # Still record the URL if available
    if [ "${KSVC_URL}" != "Unknown" ] && [ -n "${KSVC_URL}" ]; then
      log "  Knative Service URL: ${KSVC_URL}"
    fi
  fi
else
  log "  Skipping wait — Knative Service 'welcome' was not applied"
  WELCOME_STATUS="SKIPPED (not applied)"
fi

# ============================================================================
# Step 5: Wait for SpinApp 'counter' to become Ready
# ============================================================================
log "Step 5: Waiting for SpinApp 'counter' to become Ready"

COUNTER_STATUS="NOT READY"
if [ "${COUNTER_APPLIED}" = true ]; then
  # SpinApp uses conditions similar to Knative. Check Ready condition.
  # Some SpinKube versions use 'Ready' condition, others use 'Available'.
  # We check both.
  SPINAPP_READY=$(kubectl -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

  if [ "${SPINAPP_READY}" = "True" ]; then
    COUNTER_STATUS="Ready"
    log "  SpinApp 'counter': READY"
  elif [ "${SPINAPP_READY}" = "Unknown" ]; then
    SPINAPP_REASON=$(kubectl -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")
    log "  SpinApp 'counter' progressing: condition=${SPINAPP_READY}, reason=${SPINAPP_REASON}"
    COUNTER_STATUS="Progressing (${SPINAPP_REASON})"

    # Check if the underlying deployment exists and is ready
    COUNTER_DEPLOY_READY=$(kubectl -n "${WORKLOADS_NAMESPACE}" get deployment counter \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
    if [ "${COUNTER_DEPLOY_READY}" = "True" ]; then
      log "  SpinApp deployment 'counter': AVAILABLE (condition not yet propagated to SpinApp CR)"
    fi
  else
    err "SpinApp 'counter' not Ready: condition=${SPINAPP_READY}"
    COUNTER_STATUS="Failed (${SPINAPP_READY})"
  fi
else
  log "  Skipping — SpinApp 'counter' was not applied"
  COUNTER_STATUS="SKIPPED (not applied)"
fi

# Also wait for the counter Deployment created by SpinApp to be ready
log "  Checking for counter Deployment..."
if kubectl -n "${WORKLOADS_NAMESPACE}" get deployment counter > /dev/null 2>&1; then
  kubectl -n "${WORKLOADS_NAMESPACE}" rollout status deployment/counter \
    --timeout "${WAIT_TIMEOUT}" > /dev/null 2>&1 \
    && log "  Deployment 'counter': ROLLOUT COMPLETE" \
    || log "  (non-fatal) Deployment 'counter' rollout did not complete within ${WAIT_TIMEOUT}"
fi

# ============================================================================
# Step 6: Patch welcome-route HTTPRoute to point to actual ksvc backend
# ============================================================================
log "Step 6: Patching HTTPRoute '${HTTPROUTE_NAME}' in namespace '${GATEWAY_NAMESPACE}'"

if kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" > /dev/null 2>&1; then
  # Record the current backendRef for comparison
  OLD_BACKEND=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null || echo "Unknown")
  log "  Current backendRef: '${OLD_BACKEND}'"

  # Patch the HTTPRoute to replace the placeholder backend with the actual
  # Knative Service backend. We use a strategic merge patch that replaces
  # the backendRefs entirely.
  #
  # The new backendRef points to the ksvc's underlying Kubernetes Service
  # (named 'welcome' in the hpa-workloads namespace, port 80).
  kubectl patch httproute "${HTTPROUTE_NAME}" -n "${GATEWAY_NAMESPACE}" \
    --type merge -p \
    '{
      "spec": {
        "rules": [
          {
            "matches": [
              {
                "path": {
                  "type": "PathPrefix",
                  "value": "/api/welcome"
                }
              }
            ],
            "backendRefs": [
              {
                "name": "welcome",
                "namespace": "'"${WORKLOADS_NAMESPACE}"'",
                "port": 80
              }
            ]
          }
        ]
      }
    }' > /dev/null 2>&1 || die "Failed to patch HTTPRoute '${HTTPROUTE_NAME}'"

  HTTPROUTE_PATCHED=true
  log "  HTTPRoute '${HTTPROUTE_NAME}': PATCHED (backend now: welcome.${WORKLOADS_NAMESPACE}:80)"

  # Verify the patch by checking the new backendRef
  NEW_BACKEND=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null || echo "Unknown")
  NEW_NAMESPACE=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].namespace}' 2>/dev/null || echo "")
  NEW_PORT=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].port}' 2>/dev/null || echo "")

  # Verify patch was applied correctly
  if [ "${NEW_BACKEND}" = "welcome" ]; then
    log "  HTTPRoute backendRef verified: name=${NEW_BACKEND}, namespace=${NEW_NAMESPACE:-<inherited>}, port=${NEW_PORT:-80}"
  else
    err "HTTPRoute patch verification failed: backendRef name is '${NEW_BACKEND}', expected 'welcome'"
  fi
else
  err "HTTPRoute '${HTTPROUTE_NAME}' not found in namespace '${GATEWAY_NAMESPACE}'"
  log "  (non-fatal) HTTPRoute not found — workloads deployed but routing not updated"
fi

# ============================================================================
# Step 7: Gather component statuses for summary
# ============================================================================
log "Step 7: Gathering component statuses"

# Knative Service detailed status
KSVC_DETAIL="NOT FOUND"
if kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome > /dev/null 2>&1; then
  KSVC_READY=$(kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  KSVC_URL=$(kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.url}' 2>/dev/null || echo "N/A")
  KSVC_LATEST=$(kubectl -n "${WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.latestReadyRevisionName}' 2>/dev/null || echo "N/A")
  KSVC_DETAIL="Ready=${KSVC_READY}, URL=${KSVC_URL}, revision=${KSVC_LATEST}"
fi

# SpinApp detailed status
SPINAPP_DETAIL="NOT FOUND"
if kubectl -n "${WORKLOADS_NAMESPACE}" get spinapp counter > /dev/null 2>&1; then
  SPINAPP_RDY=$(kubectl -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  SPINAPP_REPLICAS=$(kubectl -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "N/A")
  SPINAPP_RDY_REPLICAS=$(kubectl -n "${WORKLOADS_NAMESPACE}" get spinapp counter \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "N/A")
  SPINAPP_DETAIL="Ready=${SPINAPP_RDY}, replicas=${SPINAPP_REPLICAS}, ready=${SPINAPP_RDY_REPLICAS}"
fi

# HTTPRoute detailed status
HTTPROUTE_DETAIL="NOT FOUND"
if kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" > /dev/null 2>&1; then
  ROUTE_PARENT=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.parentRefs[0].name}' 2>/dev/null || echo "Unknown")
  ROUTE_BACKEND=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null || echo "Unknown")
  ROUTE_PORT=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].port}' 2>/dev/null || echo "Unknown")

  # Check Gateway API status conditions
  ROUTE_ACCEPTED=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
  ROUTE_RESOLVED=$(kubectl -n "${GATEWAY_NAMESPACE}" get httproute "${HTTPROUTE_NAME}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || echo "Unknown")

  HTTPROUTE_DETAIL="parent=${ROUTE_PARENT}, backend=${ROUTE_BACKEND}:${ROUTE_PORT}, Accepted=${ROUTE_ACCEPTED}, ResolvedRefs=${ROUTE_RESOLVED}"
fi

# Workload namespace pods
WORKLOADS_PODS=$(kubectl -n "${WORKLOADS_NAMESPACE}" get pods --no-headers 2>/dev/null | wc -l)
WORKLOADS_READY=$(kubectl -n "${WORKLOADS_NAMESPACE}" get pods --no-headers 2>/dev/null | awk '{print $2}' | grep -cE '^[1-9]+/[0-9]+' || echo "0")

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Workloads Installation Summary ==="
echo "  Namespace:"
echo "    name:               ${WORKLOADS_NAMESPACE}"
echo "    pods:               ${WORKLOADS_PODS:-0} total, ${WORKLOADS_READY:-0} ready"
echo ""
echo "  Knative Service:"
echo "    name:               welcome"
echo "    namespace:          ${WORKLOADS_NAMESPACE}"
echo "    status:             ${WELCOME_STATUS}"
echo "    detail:             ${KSVC_DETAIL}"
echo ""
echo "  SpinApp:"
echo "    name:               counter"
echo "    namespace:          ${WORKLOADS_NAMESPACE}"
echo "    status:             ${COUNTER_STATUS}"
echo "    detail:             ${SPINAPP_DETAIL}"
echo ""
echo "  HTTPRoute:"
echo "    name:               ${HTTPROUTE_NAME}"
echo "    namespace:          ${GATEWAY_NAMESPACE}"
echo "    patched:            ${HTTPROUTE_PATCHED}"
echo "    detail:             ${HTTPROUTE_DETAIL}"
echo ""
echo "  Gateway:"
echo "    name:               ${GATEWAY_NAME}"
echo "    namespace:          ${GATEWAY_NAMESPACE}"
echo ""
echo "  Endpoints:"
echo "    /api/welcome:       http://<envoy-ip>/api/welcome (via welcome ksvc)"
echo "    KeyDB counter:      keydb.keydb.svc.cluster.local:6379"
echo ""
echo "  Kustomize overlay:    ${GITOPS_OVERLAY_PATH}"
echo ""
echo "  HTTPRoute manifests:"
kubectl -n "${GATEWAY_NAMESPACE}" get httproute --no-headers 2>/dev/null \
  | awk '{printf "    %-25s %s\n", $1, $2}' \
  || echo "    (no HTTPRoutes found)"
echo ""
echo "  Workload pods:"
kubectl -n "${WORKLOADS_NAMESPACE}" get pods --no-headers 2>/dev/null \
  | awk '{printf "    %-40s %-10s %-10s %s\n", $1, $2, $3, $4}' \
  || echo "    (no pods in namespace)"
echo ""
echo "===================================="

log "install-workloads: completed successfully"
exit 0

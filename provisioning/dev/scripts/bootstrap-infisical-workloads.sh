#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap-infisical-workloads.sh — Bootstrap Infisical secrets for workloads
#
# Connects to the running Infisical instance (deployed by install-infisical.sh)
# and:
#   1. Creates the hpa-workloads project in Infisical (if it doesn't exist)
#   2. Creates required secrets (COUNTER_ADDR, KEYDB_URL) in the dev environment
#   3. Creates machine identities for each workload namespace
#   4. Attaches identities to the project with read permissions
#   5. Stores identity clientId/clientSecret as K8s Secrets in each namespace
#      so the Infisical Secrets Operator can consume them
#
# Uses the Infisical REST API (v4 secrets, v1 projects, v1 identities).
# For self-hosted deployments, API base URL is http://<infisical-lb-ip>:8080.
#
# Idempotent: safe to re-run — skips existing projects, secrets, and
# identities. Updates K8s Secrets if they already exist.
#
# Prerequisites:
#   - install-infisical.sh has completed successfully
#   - Infisical Secrets Operator is running
#   - kubectl and curl available
#   - INFISICAL_ADMIN_PASSWORD set in .env
#
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./bootstrap-infisical-workloads.sh [--kubeconfig <path>]
#                                           [--infisical-ns <ns>]
#                                           [--admin-email <email>]
#                                           [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Required environment variables (fail fast if missing from .env) ---
require_env INFISICAL_ADMIN_PASSWORD

# ---- Internal defaults (script-internal only) -------------------------
INFISICAL_NAMESPACE="infisical"
ADMIN_EMAIL="admin@infisical.com"
WAIT_TIMEOUT=300
INFISICAL_PORT=8080

# Workload secrets to create in Infisical (env var name -> default value)
# These are non-sensitive configuration values that workloads consume
# via the Infisical Secrets Operator.
declare -A WORKLOAD_SECRETS
WORKLOAD_SECRETS["COUNTER_ADDR"]="http://counter.hpa-workloads.svc.cluster.local:8080"
WORKLOAD_SECRETS["KEYDB_URL"]="redis://keydb.keydb.svc.cluster.local:6379/"

# Workload namespaces that need Infisical machine identities
WORKLOAD_NAMESPACES=("hpa-workloads" "casbin" "hasura")

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG="$2";               shift 2 ;;
    --infisical-ns)      INFISICAL_NAMESPACE="$2";       shift 2 ;;
    --admin-email)       ADMIN_EMAIL="$2";               shift 2 ;;
    --wait-timeout)      WAIT_TIMEOUT="$2";              shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Bootstrap Infisical secrets for workloads. Creates project, secrets, and
machine identities for the Infisical Secrets Operator.

Required environment variables:
  INFISICAL_ADMIN_PASSWORD   Admin password for Infisical

Options:
  --kubeconfig PATH       Path to kubeconfig (default: ../opentofu/kubeconfig)
  --infisical-ns NS       Infisical namespace (default: infisical)
  --admin-email EMAIL     Infisical admin email (default: admin@infisical.com)
  --wait-timeout DUR      Timeout for LB IP and API (default: 5m)
  --help, -h              Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "bootstrap-infisical-workloads: starting"
log "  kubeconfig:        ${KUBECONFIG}"
log "  infisical-ns:      ${INFISICAL_NAMESPACE}"
log "  admin-email:       ${ADMIN_EMAIL}"
log "  wait-timeout:      ${WAIT_TIMEOUT}s"
log "  namespaces:        ${WORKLOAD_NAMESPACES[*]}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v curl >/dev/null 2>&1   || die "curl not found in PATH"
[ -f "${KUBECONFIG}" ]            || die "kubeconfig not found at ${KUBECONFIG}"

# ---- State tracking -------------------------------------------------------
INFISICAL_LB=""              # Infisical LoadBalancer IP
ACCESS_TOKEN=""               # Admin Bearer token
PROJECT_ID=""                 # hpa-workloads project ID
ENV_SLUG="dev"                # Environment slug

CREATED_PROJECT=false
CREATED_SECRETS=0
CREATED_IDENTITIES=0
CREATED_K8S_SECRETS=0

# ---- Helper: infisical_api -------------------------------------------------
# Convenience wrapper for Infisical API calls. Echoes body on success, returns
# the HTTP status code. Error response bodies are logged.
infisical_api() {
  local method="$1"
  local path="$2"
  local data="$3"
  local auth_header=""
  local result
  local http_code
  local body_file

  if [ -n "${ACCESS_TOKEN}" ]; then
    auth_header="Authorization: Bearer ${ACCESS_TOKEN}"
  fi

  body_file="$(mktemp)"

  set +e
  if [ -n "${data}" ]; then
    result=$(curl -s -w "%{http_code}" -X "${method}" \
      "${INFISICAL_LB}:${INFISICAL_PORT}${path}" \
      -H "Content-Type: application/json" \
      ${auth_header:+-H "${auth_header}"} \
      -d "${data}" \
      --connect-timeout 5 --max-time 15 \
      -o "${body_file}" 2>&1)
  else
    result=$(curl -s -w "%{http_code}" -X "${method}" \
      "${INFISICAL_LB}:${INFISICAL_PORT}${path}" \
      ${auth_header:+-H "${auth_header}"} \
      --connect-timeout 5 --max-time 15 \
      -o "${body_file}" 2>&1)
  fi
  set -e

  http_code="${result: -3}"
  body="$(cat "${body_file}")"
  rm -f "${body_file}"

  # Output body so callers can parse it
  echo "${body}"

  # Return the HTTP status code
  return "${http_code:-0}"
}

# ---- Wait for Infisical LB IP ---------------------------------------------
log "Waiting for Infisical LoadBalancer IP..."
for i in $(seq 1 30); do
  INFISICAL_LB=$(kubectl -n "${INFISICAL_NAMESPACE}" get svc infisical \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "${INFISICAL_LB}" ]; then
    log "  Infisical LB IP: ${INFISICAL_LB}"
    break
  fi
  log "  Waiting for LB IP (attempt ${i}/30)..."
  sleep 5
done

if [ -z "${INFISICAL_LB}" ]; then
  die "Infisical LoadBalancer IP not assigned within polling window"
fi

# ---- Wait for Infisical API to be reachable --------------------------------
log "Waiting for Infisical API to be reachable at http://${INFISICAL_LB}:${INFISICAL_PORT}..."
for i in $(seq 1 30); do
  if curl -s -o /dev/null -w "%{http_code}" \
    "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/health" \
    --connect-timeout 5 --max-time 10 > /dev/null 2>&1; then
    log "  Infisical API reachable (attempt ${i})"
    break
  fi
  if [ "${i}" -eq 30 ]; then
    die "Infisical API not reachable after 30 attempts at http://${INFISICAL_LB}:${INFISICAL_PORT}"
  fi
  log "  Waiting for API (attempt ${i}/30)..."
  sleep 5
done

# ============================================================================
# Phase 1: Authenticate as admin
# ============================================================================
log "Phase 1: Authenticating as ${ADMIN_EMAIL}..."
AUTH_RESULT=$(curl -s -X POST \
  "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${INFISICAL_ADMIN_PASSWORD}\"}" \
  --connect-timeout 5 --max-time 15 2>&1) || {
  # Fallback: try login2 endpoint (some Infisical versions use /api/v1/auth/login2)
  log "  Primary login endpoint failed; trying login2..."
  AUTH_RESULT=$(curl -s -X POST \
    "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/auth/login2" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${INFISICAL_ADMIN_PASSWORD}\"}" \
    --connect-timeout 5 --max-time 15 2>&1) || {
    log "  login2 also failed; trying login with configurable endpoint..."
    # Try /api/v3/auth/login as another fallback
    AUTH_RESULT=$(curl -s -X POST \
      "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v3/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${INFISICAL_ADMIN_PASSWORD}\"}" \
      --connect-timeout 5 --max-time 15 2>&1) || true
  }
}

ACCESS_TOKEN=$(echo "${AUTH_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('accessToken', data.get('token', '')))
except Exception:
    print('')
" 2>/dev/null || true)

if [ -z "${ACCESS_TOKEN}" ]; then
  die "Failed to authenticate with Infisical as ${ADMIN_EMAIL}. Verify INFISICAL_ADMIN_PASSWORD."
fi
log "  Authentication: SUCCESS (token acquired)"

# ============================================================================
# Phase 2: Create hpa-workloads project
# ============================================================================
log "Phase 2: Creating/finding hpa-workloads project..."

# Check if project already exists
PROJECTS_RESULT=$(curl -s -X GET \
  "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/projects" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  --connect-timeout 5 --max-time 15 2>&1)

PROJECT_ID=$(echo "${PROJECTS_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    projects = data.get('projects', [])
    for p in projects:
        if p.get('name') == 'hpa-workloads' or p.get('slug') == 'hpa-workloads':
            print(p['id'])
            break
except Exception:
    pass
" 2>/dev/null || true)

if [ -z "${PROJECT_ID}" ]; then
  log "  Creating new project 'hpa-workloads'..."
  CREATE_PROJECT_RESULT=$(curl -s -X POST \
    "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/projects" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name":"hpa-workloads","slug":"hpa-workloads"}' \
    --connect-timeout 5 --max-time 15 2>&1)

  PROJECT_ID=$(echo "${CREATE_PROJECT_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('project', data).get('id', ''))
except Exception:
    print('')
" 2>/dev/null || true)

  if [ -z "${PROJECT_ID}" ]; then
    die "Failed to create Infisical project 'hpa-workloads'. Response: ${CREATE_PROJECT_RESULT}"
  fi
  CREATED_PROJECT=true
  log "  Project 'hpa-workloads' created: ${PROJECT_ID}"
else
  log "  Project 'hpa-workloads' already exists: ${PROJECT_ID}"
fi

# Get or determine the dev environment slug
log "  Detecting project environments..."
ENVS_RESULT=$(curl -s -X GET \
  "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/projects/${PROJECT_ID}/environments" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  --connect-timeout 5 --max-time 15 2>&1)

ENV_SLUG=$(echo "${ENVS_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    envs = data.get('environments', [])
    for e in envs:
        slug = e.get('slug', '')
        if slug in ('dev', 'development'):
            print(slug)
            break
    if not envs:
        print('dev')
except Exception:
    print('dev')
" 2>/dev/null || echo "dev")

log "  Using environment: ${ENV_SLUG}"

# ============================================================================
# Phase 3: Create secrets in the dev environment
# ============================================================================
log "Phase 3: Creating secrets in hpa-workloads/${ENV_SLUG}..."

for secret_name in "${!WORKLOAD_SECRETS[@]}"; do
  secret_value="${WORKLOAD_SECRETS[$secret_name]}"

  log "  Creating/finding secret '${secret_name}'..."

  # Check if secret already exists
  EXISTING_SECRET=$(curl -s -X GET \
    "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v4/secrets/${secret_name}?projectId=${PROJECT_ID}&environment=${ENV_SLUG}&secretPath=/" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    --connect-timeout 5 --max-time 15 2>&1)

  EXISTING_CHECK=$(echo "${EXISTING_SECRET}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    secret = data.get('secret', {})
    if secret.get('secretName'):
        print('EXISTS')
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || true)

  if [ "${EXISTING_CHECK}" = "EXISTS" ]; then
    log "    Secret '${secret_name}' already exists — skipping"
    continue
  fi

  # Create secret
  CREATE_RESULT=$(curl -s -X POST \
    "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v4/secrets/${secret_name}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"projectId\":\"${PROJECT_ID}\",\"environment\":\"${ENV_SLUG}\",\"secretPath\":\"/\",\"secretValue\":\"${secret_value}\",\"type\":\"shared\"}" \
    --connect-timeout 5 --max-time 15 2>&1)

  CREATE_ERROR=$(echo "${CREATE_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('error', data.get('message', '')))
except Exception:
    print('parse_error')
" 2>/dev/null || true)

  if [ -n "${CREATE_ERROR}" ] && [ "${CREATE_ERROR}" != "parse_error" ]; then
    err "Failed to create secret '${secret_name}': ${CREATE_ERROR}"
  else
    CREATED_SECRETS=$((CREATED_SECRETS + 1))
    log "    Secret '${secret_name}': CREATED"
  fi
done

# ============================================================================
# Phase 4: Create machine identities for workload namespaces
# ============================================================================
log "Phase 4: Creating machine identities for workload namespaces..."

for ns in "${WORKLOAD_NAMESPACES[@]}"; do
  identity_name="hpa-${ns}"
  log "  Processing namespace '${ns}' (identity: ${identity_name})..."

  # Check if identity already exists
  IDENTITIES_RESULT=$(curl -s -X GET \
    "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/identities" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    --connect-timeout 5 --max-time 15 2>&1)

  EXISTING_ID=$(echo "${IDENTITIES_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for identity in data.get('identities', []):
        if identity.get('name') == '${identity_name}':
            print(identity['id'])
            break
except Exception:
    pass
" 2>/dev/null || true)

  if [ -n "${EXISTING_ID}" ]; then
    log "    Identity '${identity_name}' already exists: ${EXISTING_ID}"

    # Get the clientId/clientSecret from the existing identity
    UA_CONFIG=$(curl -s -X GET \
      "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/auth/universal-auth/identities/${EXISTING_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      --connect-timeout 5 --max-time 15 2>&1)

    CLIENT_ID=$(echo "${UA_CONFIG}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('clientId', data.get('identityUniversalAuth', {}).get('clientId', '')))
except Exception:
    print('')
" 2>/dev/null || true)
    CLIENT_SECRET=$(echo "${UA_CONFIG}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('clientSecret', data.get('identityUniversalAuth', {}).get('clientSecret', '')))
except Exception:
    print('')
" 2>/dev/null || true)
  else
    # Create identity
    log "    Creating identity '${identity_name}'..."
    CREATE_ID_RESULT=$(curl -s -X POST \
      "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/identities" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${identity_name}\"}" \
      --connect-timeout 5 --max-time 15 2>&1)

    EXISTING_ID=$(echo "${CREATE_ID_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('identity', data).get('id', ''))
except Exception:
    print('')
" 2>/dev/null || true)

    if [ -z "${EXISTING_ID}" ]; then
      err "Failed to create identity '${identity_name}'"
      continue
    fi
    log "    Identity '${identity_name}' created: ${EXISTING_ID}"

    # Configure Universal Auth for this identity
    log "    Configuring Universal Auth..."
    UA_RESULT=$(curl -s -X POST \
      "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/auth/universal-auth/identities/${EXISTING_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"accessTokenTTL":3600,"accessTokenMaxTTL":86400}' \
      --connect-timeout 5 --max-time 15 2>&1)

    # Extract clientId and clientSecret from the response
    # The POST to universal-auth returns the credentials in the response
    CLIENT_ID=$(echo "${UA_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('clientId', data.get('identityUniversalAuth', {}).get('clientId', '')))
except Exception:
    print('')
" 2>/dev/null || true)
    CLIENT_SECRET=$(echo "${UA_RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('clientSecret', data.get('identityUniversalAuth', {}).get('clientSecret', '')))
except Exception:
    print('')
" 2>/dev/null || true)

    if [ -z "${CLIENT_ID}" ] || [ -z "${CLIENT_SECRET}" ]; then
      err "Failed to extract client credentials for identity '${identity_name}'"
      continue
    fi

    # Attach identity to the project as a member with read role
    log "    Attaching identity to project 'hpa-workloads'..."

    # Add identity to project — use the memberships endpoint
    # This typically requires POST /api/v1/projects/<projectId>/memberships
    # or PUT /api/v1/projects/<projectId>/identities/<identityId>
    ATTACH_RESULT=$(curl -s -X POST \
      "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/projects/${PROJECT_ID}/memberships" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"identityId\":\"${EXISTING_ID}\",\"role\":\"member\"}" \
      --connect-timeout 5 --max-time 15 2>&1) || {
      # Fallback: try PUT /api/v1/projects/<projectId>/identities/<identityId>
      log "    (membership via POST failed; trying PUT pattern...)"
      ATTACH_RESULT=$(curl -s -X PUT \
        "http://${INFISICAL_LB}:${INFISICAL_PORT}/api/v1/projects/${PROJECT_ID}/identities/${EXISTING_ID}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"roles\":[{\"role\":\"member\"}]}" \
        --connect-timeout 5 --max-time 15 2>&1) || true
    }

    CREATED_IDENTITIES=$((CREATED_IDENTITIES + 1))
    log "    Identity '${identity_name}': READY"
  fi

  # ---- Store clientId/clientSecret as K8s Secret in the workload namespace
  if [ -n "${CLIENT_ID}" ] && [ -n "${CLIENT_SECRET}" ]; then
    log "    Ensuring namespace '${ns}' exists..."
    kubectl create namespace "${ns}" --dry-run=client -o yaml \
      | kubectl apply -f - > /dev/null 2>&1 || true

    log "    Creating/updating K8s Secret 'infisical-auth' in namespace '${ns}'..."
    kubectl -n "${ns}" create secret generic "infisical-auth" \
      --from-literal="clientId=${CLIENT_ID}" \
      --from-literal="clientSecret=${CLIENT_SECRET}" \
      --dry-run=client -o yaml \
      | kubectl apply -f - > /dev/null 2>&1
    CREATED_K8S_SECRETS=$((CREATED_K8S_SECRETS + 1))
    log "    K8s Secret 'infisical-auth' in '${ns}': CREATED/UPDATED"
  else
    err "No client credentials for identity '${identity_name}' — cannot create K8s Secret"
  fi
done

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Infisical Workload Bootstrap Summary ==="
echo "  Infisical host:      http://${INFISICAL_LB}:${INFISICAL_PORT}"
echo "  Project:             hpa-workloads (${PROJECT_ID})"
echo "  Environment:         ${ENV_SLUG}"
echo ""
echo "  Secrets created:     ${CREATED_SECRETS}"
echo "  Identities created:  ${CREATED_IDENTITIES}"
echo "  K8s Secrets stored:  ${CREATED_K8S_SECRETS}"
echo "  Project created:     ${CREATED_PROJECT}"
echo ""
echo "  Workload secrets:"
for secret_name in "${!WORKLOAD_SECRETS[@]}"; do
  echo "    ${secret_name}"
done
echo ""
echo "  Machine identities:"
for ns in "${WORKLOAD_NAMESPACES[@]}"; do
  echo "    hpa-${ns} -> K8s Secret infisical-auth in namespace '${ns}'"
done
echo ""
echo "==========================================="

log "bootstrap-infisical-workloads: completed successfully"
exit 0

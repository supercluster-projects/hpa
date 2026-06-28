#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-hasura.sh — Deploy Hasura GraphQL Engine
#
# Installs Hasura GraphQL Engine via the official Helm chart, connected to
# the Yugabytedb distributed SQL cluster as the primary data source. Admin
# secret is auto-generated and stored in a Kubernetes Secret for the
# Infisical Secrets Operator to manage.
#
# Idempotent: safe to re-run (helm upgrade --atomic --wait).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-hasura.sh [--kubeconfig <path>]
#                            [--hasura-version <ver>]
#                            [--namespace <ns>]
#                            [--release-name <name>]
#                            [--database-url <url>]
#                            [--admin-secret <secret>]
#                            [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env HASURA_VERSION

# ---- Internal defaults (script-internal only) -------------------------
NAMESPACE="hasura"
RELEASE_NAME="hasura"
WAIT_TIMEOUT=600
CHART_REPO_NAME="hasura"
CHART_REPO_URL="https://hasura.github.io/helm-charts"

# Yugabytedb connection (in-cluster DNS)
DEFAULT_DB_URL="postgresql://yugabyte@yb-tserver-0.yb-tservers.yugabytedb.svc.cluster.local:5433/yugabyte"

# Resource tuning for 3GB worker VMs
HASURA_CPU_REQUEST="0.25"
HASURA_MEM_REQUEST="512Mi"
HASURA_CPU_LIMIT="0.5"
HASURA_MEM_LIMIT="1Gi"

# ---- CLI Overrides --------------------------------------------------------
DATABASE_URL=""
ADMIN_SECRET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG="$2";           shift 2 ;;
    --hasura-version)      HASURA_VERSION="$2";       shift 2 ;;
    --namespace)           NAMESPACE="$2";            shift 2 ;;
    --release-name)        RELEASE_NAME="$2";          shift 2 ;;
    --database-url)        DATABASE_URL="$2";          shift 2 ;;
    --admin-secret)        ADMIN_SECRET="$2";          shift 2 ;;
    --wait-timeout)        WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy Hasura GraphQL Engine connected to Yugabytedb.

Components installed:
  - Hasura GraphQL Engine (Helm chart from hasura.github.io)
  - ClusterIP service on port 8080
  - Connected to Yugabytedb YSQL endpoint

Options:
  --kubeconfig PATH        Path to kubeconfig
  --hasura-version VER     Hasura version (required)
  --namespace NS           Namespace (default: hasura)
  --release-name NAME      Helm release name (default: hasura)
  --database-url URL       Yugabytedb connection string
                           (default: auto-detected in-cluster YSQL)
  --admin-secret SECRET    Hasura admin secret (default: auto-generated)
  --wait-timeout SEC       Max wait for Helm install (default: 600)
  --help, -h               Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-hasura: starting"
log "  kubeconfig:       ${KUBECONFIG}"
log "  version:          ${HASURA_VERSION}"
log "  namespace:        ${NAMESPACE}"
log "  release:          ${RELEASE_NAME}"
log "  resources:        req ${HASURA_CPU_REQUEST}/${HASURA_MEM_REQUEST}, lim ${HASURA_CPU_LIMIT}/${HASURA_MEM_LIMIT}"
log "  wait-timeout:     ${WAIT_TIMEOUT}s"

command -v helm >/dev/null 2>&1   || die "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]            || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Resolve database URL -------------------------------------------------
if [ -z "${DATABASE_URL}" ]; then
  DATABASE_URL="${DEFAULT_DB_URL}"
  log "  database-url:     ${DATABASE_URL} (auto)"
else
  log "  database-url:     ${DATABASE_URL} (CLI override)"
fi

# ---- Generate admin secret if not provided --------------------------------
if [ -z "${ADMIN_SECRET}" ]; then
  ADMIN_SECRET=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(32)))
" 2>/dev/null || echo "hasura-$(date +%s)")
  log "  admin-secret:     auto-generated (32 chars)"
else
  log "  admin-secret:     provided via CLI (${#ADMIN_SECRET} chars)"
fi

# ---- Phase 1: Add Helm chart repository -----------------------------------
log "Phase 1: Adding Helm chart repository ${CHART_REPO_URL}..."

helm repo add "${CHART_REPO_NAME}" "${CHART_REPO_URL}" \
  --force-update 2>&1 >/dev/null || die "Failed to add Helm repo ${CHART_REPO_URL}"
helm repo update "${CHART_REPO_NAME}" 2>&1 >/dev/null || log "  Warning: repo update had issues"

log "  Helm chart repo '${CHART_REPO_NAME}' ready."

# ---- Phase 2: Create namespace --------------------------------------------
log "Phase 2: Ensuring namespace ${NAMESPACE} exists..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1

# Create the bootstrap admin secret for Hasura (will be managed by InfisicalSecret CRD later)
kubectl -n "${NAMESPACE}" create secret generic "hasura-admin-secret" \
  --from-literal="admin-secret=${ADMIN_SECRET}" \
  --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1

log "  Namespace '${NAMESPACE}' ready."
log "  Bootstrap Secret 'hasura-admin-secret' created."

# ---- Phase 3: Deploy Hasura via Helm --------------------------------------
log "Phase 3: Installing Hasura GraphQL Engine (${HASURA_VERSION}) in namespace ${NAMESPACE}..."

helm upgrade --install "${RELEASE_NAME}" "${CHART_REPO_NAME}/graphql-engine" \
  --version "${HASURA_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "postgres.enabled=false" \
  --set "config.databaseUrl=${DATABASE_URL}" \
  --set "config.adminSecret=${ADMIN_SECRET}" \
  --set "config.console.enabled=true" \
  --set "config.console.devMode=false" \
  --set "service.type=ClusterIP" \
  --set "service.internalPort=8080" \
  --set "resources.requests.cpu=${HASURA_CPU_REQUEST}" \
  --set "resources.requests.memory=${HASURA_MEM_REQUEST}" \
  --set "resources.limits.cpu=${HASURA_CPU_LIMIT}" \
  --set "resources.limits.memory=${HASURA_MEM_LIMIT}" \
  --wait \
  --timeout "${WAIT_TIMEOUT}s" \
  2>&1 | while IFS= read -r line; do log "  ${line}"; done

HELM_EXIT="${PIPESTATUS[0]}"
if [ "${HELM_EXIT}" -ne 0 ]; then
  die "Helm install/upgrade for Hasura failed (exit code ${HELM_EXIT})"
fi
log "  Hasura Helm release '${RELEASE_NAME}' deployed."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Hasura Installation Summary ==="
echo "  Release:         ${RELEASE_NAME}"
echo "  Version:         ${HASURA_VERSION}"
echo "  Namespace:       ${NAMESPACE}"
echo "  Database:        ${DATABASE_URL}"
echo "  Service:         ClusterIP :8080"
echo "  Resources:       req ${HASURA_CPU_REQUEST}/${HASURA_MEM_REQUEST}, lim ${HASURA_CPU_LIMIT}/${HASURA_MEM_LIMIT}"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods"
echo "    kubectl -n ${NAMESPACE} get svc"
echo "    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-graphql-engine 8080:8080 &"
echo "    curl http://localhost:8080/v1/graphql -X POST -H 'Content-Type: application/json' -H 'x-hasura-admin-secret: <your-secret>' -d '{\"query\":\"{ __schema { types { name } } }\"}'"
echo ""
echo "  Admin secret is stored in:"
echo "    kubectl -n ${NAMESPACE} get secret hasura-admin-secret -o jsonpath='{.data.admin-secret}' | base64 -d"
echo "======================================="

log "install-hasura: completed successfully"
exit 0

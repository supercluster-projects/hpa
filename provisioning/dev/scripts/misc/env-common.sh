#!/usr/bin/env bash
# env-common.sh — Centralized environment variables to avoid DRY violations
#
# Source this file in other scripts:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env-common.sh"
#
# This file defines all common constants used across the provisioning scripts
# to ensure consistency and avoid duplicated values.

set -euo pipefail

# ---------------------------------------------------------------------------
# Network Configuration (Single Source of Truth)
# ---------------------------------------------------------------------------

# CIDR Base and Block
export CIDR_BASE="${CIDR_BASE:-192.168.122}"
export CIDR_BLOCK="${CIDR_BLOCK:-${CIDR_BASE}.0/24}"
export CIDR_PREFIX="${CIDR_PREFIX:-24}"

# Gateway and DNS
export GATEWAY_IP="${GATEWAY_IP:-${CIDR_BASE}.1}"
export CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-${CIDR_BASE}.100}"

# Control Plane IPs
export CP_IP_0="${CP_IP_0:-${CIDR_BASE}.100}"
export CP_IP_1="${CP_IP_1:-${CIDR_BASE}.101}"

# Worker IPs
export WORKER_IP_0="${WORKER_IP_0:-${CIDR_BASE}.110}"
export WORKER_IP_1="${WORKER_IP_1:-${CIDR_BASE}.111}"
export WORKER_IP_2="${WORKER_IP_2:-${CIDR_BASE}.112}"

# LoadBalancer Pool (last /28)
export LB_POOL_CIDR="${LB_POOL_CIDR:-${CIDR_BASE}.208/28}"
export ENVOY_LB_IP="${ENVOY_LB_IP:-${CIDR_BASE}.210}"

# ---------------------------------------------------------------------------
# Cluster and Node Configuration
# ---------------------------------------------------------------------------

# Cluster name
export DEV_CLUSTER_NAME="${DEV_CLUSTER_NAME:-hpa-dev}"

# Node prefix
export NODE_PREFIX="${NODE_PREFIX:-hpa-node}"

# Talos version
export TALOS_VERSION="${TALOS_VERSION:-v1.13.5}"

# Libvirt bridge
export DEV_BRIDGE_NAME="${DEV_BRIDGE_NAME:-hpa-bridge}"

# ---------------------------------------------------------------------------
# Kubernetes Namespaces
# ---------------------------------------------------------------------------

export WORKLOADS_NAMESPACE="${WORKLOADS_NAMESPACE:-hpa-workloads}"
export GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-envoy-gateway-system}"
export INFRASTRUCTURE_NAMESPACE="${INFRASTRUCTURE_NAMESPACE:-infrastructure}"
export KARGO_NAMESPACE="${KARGO_NAMESPACE:-kargo}"
export ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
export BACKSTAGE_NAMESPACE="${BACKSTAGE_NAMESPACE:-backstage}"
export INFISICAL_NAMESPACE="${INFISICAL_NAMESPACE:-infisical}"
export KEYDB_NAMESPACE="${KEYDB_NAMESPACE:-keydb}"
export HARBOR_NAMESPACE="${HARBOR_NAMESPACE:-harbor}"
export CASDOOR_NAMESPACE="${CASDOOR_NAMESPACE:-casdoor}"
export CASBIN_NAMESPACE="${CASBIN_NAMESPACE:-casbin}"

# ---------------------------------------------------------------------------
# Service Endpoints
# ---------------------------------------------------------------------------

# Harbor
export HARBOR_INTERNAL_URL="${HARBOR_INTERNAL_URL:-http://harbor.harbor.svc.cluster.local}"
export HARBOR_PROJECT="${HARBOR_PROJECT:-hpa-workloads}"

# Infisical
export INFISICAL_API="${INFISICAL_API:-http://infisical.infisical.svc.cluster.local:8080}"

# KeyDB/Redis
export KEYDB_URL="${KEYDB_URL:-redis://keydb.keydb.svc.cluster.local:6379/}"

# ---------------------------------------------------------------------------
# Service Ports
# ---------------------------------------------------------------------------

export BACKSTAGE_PORT="${BACKSTAGE_PORT:-7007}"
export COUNTER_PORT="${COUNTER_PORT:-8080}"
export STREAM_PORT="${STREAM_PORT:-8080}"
export WELCOME_PORT="${WELCOME_PORT:-8080}"
export CASBIN_GRPC_PORT="${CASBIN_GRPC_PORT:-9001}"
export HARBOR_PORT="${HARBOR_PORT:-443}"
export KEYDB_PORT="${KEYDB_PORT:-6379}"

# ---------------------------------------------------------------------------
# Common Service Names
# ---------------------------------------------------------------------------

export ENTITY_COUNTER="${ENTITY_COUNTER:-counter}"
export ENTITY_STREAM="${ENTITY_STREAM:-stream}"
export ENTITY_WELCOME="${ENTITY_WELCOME:-welcome}"
export ENTITY_CASBIN="${ENTITY_CASBIN:-casbin-ext-authz}"
export ENTITY_HASURA="${ENTITY_HASURA:-hasura-graphql-engine}"
export ENTITY_ENVOY="${ENTITY_ENVOY:-envoy-gateway}"

# ---------------------------------------------------------------------------
# Helper Functions for Debugging
# ---------------------------------------------------------------------------

# Print all current environment variables (for debugging)
print_env() {
  echo "=== Network Configuration ==="
  echo "CIDR_BASE: ${CIDR_BASE}"
  echo "CIDR_BLOCK: ${CIDR_BLOCK}"
  echo "GATEWAY_IP: ${GATEWAY_IP}"
  echo "CONTROL_PLANE_IP: ${CONTROL_PLANE_IP}"
  echo "LB_POOL_CIDR: ${LB_POOL_CIDR}"
  echo "ENVOY_LB_IP: ${ENVOY_LB_IP}"
  echo ""
  echo "=== Namespaces ==="
  echo "WORKLOADS_NAMESPACE: ${WORKLOADS_NAMESPACE}"
  echo "GATEWAY_NAMESPACE: ${GATEWAY_NAMESPACE}"
  echo "KARGO_NAMESPACE: ${KARGO_NAMESPACE}"
  echo "ARGOCD_NAMESPACE: ${ARGOCD_NAMESPACE}"
  echo ""
  echo "=== Service Endpoints ==="
  echo "HARBOR_INTERNAL_URL: ${HARBOR_INTERNAL_URL}"
  echo "INFISICAL_API: ${INFISICAL_API}"
  echo "KEYDB_URL: ${KEYDB_URL}"
}

# Validate that required environment variables are set
validate_env() {
  local missing=0
  local required_vars=(
    "CIDR_BASE"
    "CIDR_BLOCK"
    "TALOS_VERSION"
  )

  for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
      echo "ERROR: Required environment variable ${var} is not set"
      missing=1
    fi
  done

  if [ $missing -eq 1 ]; then
    return 1
  fi
}
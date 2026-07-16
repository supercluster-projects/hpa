#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# prep-cache.sh — Pre-cache offline assets for HPA dev cluster provisioning
#
# Downloads the Talos qcow2 image and caches OpenTofu provider plugins so
# provisioning can proceed without internet connectivity.
#
# Idempotent: safe to re-run (skips existing files; use --force to re-download).
#
# Usage: ./prep-cache.sh [options]
#
# Options:
#   --cache-dir PATH    Offline asset cache directory (default: .cache in project root)
#   --tofu-dir PATH     Path to OpenTofu provisioning directory
#   --env-file PATH     Path to .env file (default: project root .env)
#   --force             Re-download cached assets even if cached
#   --help, -h          Show this help message
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Internal defaults ----------------------------------------------------
TOFU_DIR="${SCRIPT_DIR}/../opentofu"
CACHE_DIR="${DEV_CACHE_DIR:-${PROJECT_ROOT}/.cache}"
ENV_FILE="${PROJECT_ROOT}/.env"
FORCE_CACHE=false

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache-dir)    CACHE_DIR="$2";   shift 2 ;;
    --tofu-dir)     TOFU_DIR="$2";    shift 2 ;;
    --env-file)     ENV_FILE="$2";    shift 2 ;;
    --force)        FORCE_CACHE=true; shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Pre-cache offline assets: Talos qcow2 image + OpenTofu provider plugins.

Options:
  --cache-dir PATH    Cache directory (default: ${CACHE_DIR})
  --tofu-dir PATH     Tofu directory (default: ${TOFU_DIR})
  --env-file PATH     .env path (default: ${ENV_FILE})
  --force             Re-download cached assets
  --help, -h          Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

log "prep-cache: caching offline assets"
log "  Cache dir:  ${CACHE_DIR}"
log "  Tofu dir:   ${TOFU_DIR}"
log "  Env file:   ${ENV_FILE}"
mkdir -p "${CACHE_DIR}"

# ============================================================================
# Step 1: Cache Talos qcow2 image
# ============================================================================
log "Step 1/2: Caching Talos qcow2 image"

# Source .env for TALOS_VERSION, DEV_TALOS_IMAGE_FACTORY_URL
set -a
[ -f "${ENV_FILE}" ] && source "${ENV_FILE}"
set +a

TALOS_VERSION="${TALOS_VERSION:-v1.13.5}"
TALOS_SCHEMATIC_ID="${TALOS_SCHEMATIC_ID:-376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba}"
IMAGE_FACTORY_URL="${DEV_TALOS_IMAGE_FACTORY_URL:-https://factory.talos.dev/image}"
QCOW2_URL="${IMAGE_FACTORY_URL}/${TALOS_SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.qcow2"
QCOW2_FILENAME="talos-${TALOS_VERSION}-metal-amd64.qcow2"
QCOW2_OUTPUT="${CACHE_DIR}/${QCOW2_FILENAME}"

if [ -f "${QCOW2_OUTPUT}" ] && [ "${FORCE_CACHE}" = false ]; then
  QCOW2_SIZE=$(stat --printf="%s" "${QCOW2_OUTPUT}" 2>/dev/null || stat -f%z "${QCOW2_OUTPUT}" 2>/dev/null || echo "?")
  log "  Talos qcow2 already cached: ${QCOW2_OUTPUT} (${QCOW2_SIZE} bytes)"
else
  if [ "${FORCE_CACHE}" = true ]; then
    log "  --force set — re-downloading..."
  fi
  log "  Downloading Talos qcow2 from:"
  log "    ${QCOW2_URL}"
  log "  (This may take a few minutes — the image is ~500MB)"

  if command -v wget > /dev/null 2>&1; then
    wget -O "${QCOW2_OUTPUT}" "${QCOW2_URL}" 2>&1
  else
    curl -sL -o "${QCOW2_OUTPUT}" "${QCOW2_URL}" 2>&1
  fi

  if [ -f "${QCOW2_OUTPUT}" ]; then
    QCOW2_SIZE=$(stat --printf="%s" "${QCOW2_OUTPUT}" 2>/dev/null || stat -f%z "${QCOW2_OUTPUT}" 2>/dev/null || echo "?")
    log "  Talos qcow2 cached: ${QCOW2_OUTPUT} (${QCOW2_SIZE} bytes)"
  else
    log "  WARNING: qcow2 download failed. Check network connectivity and TALOS_VERSION."
    log "  Manual download: wget ${QCOW2_URL} -O ${QCOW2_OUTPUT}"
  fi
fi

# ============================================================================
# Step 2: Cache OpenTofu providers (tofu init)
# ============================================================================
log "Step 2/2: Caching OpenTofu providers"

if [ -d "${TOFU_DIR}" ]; then
  log "  Running tofu init in ${TOFU_DIR}..."

  if command -v tofu > /dev/null 2>&1; then
    tofu -chdir="${TOFU_DIR}" init -upgrade 2>&1
    TOFU_INIT_EXIT=$?

    if [ "${TOFU_INIT_EXIT}" -eq 0 ]; then
      log "  tofu init: SUCCESS"
      PROVIDER_COUNT=$(find "${TOFU_DIR}/.terraform/providers" -type f 2>/dev/null | wc -l)
      log "  Cached providers: ${PROVIDER_COUNT} files in ${TOFU_DIR}/.terraform/providers"
    else
      log "  WARNING: tofu init had issues (exit ${TOFU_INIT_EXIT})"
    fi
  else
    log "  tofu binary not available — skipping provider cache"
  fi
else
  log "  OpenTofu directory not found at ${TOFU_DIR}"
  log "  Cannot cache providers without a tofu project directory."
fi

# Write cache.auto.tfvars to point tofu at local cache
CACHE_TFVARS="${TOFU_DIR}/cache.auto.tfvars"
if [ ! -f "${CACHE_TFVARS}" ] || [ "${FORCE_CACHE}" = true ]; then
  cat > "${CACHE_TFVARS}" <<TFVARSEOF
# Auto-generated by prep-cache.sh — enables offline mode
# Point Talos image source to local cache
local_image_path = "${QCOW2_OUTPUT}"
TFVARSEOF
  log "  Cache vars written to ${CACHE_TFVARS}"
fi

# Summary
echo ""
echo "=== Cache Preparation Summary ==="
QCOW2_SIZE=$(stat --printf="%s" "${QCOW2_OUTPUT}" 2>/dev/null || stat -f%z "${QCOW2_OUTPUT}" 2>/dev/null || echo "0")
if [ "${QCOW2_SIZE}" -gt 0 ]; then
  QCOW2_HUMAN=$(( QCOW2_SIZE / 1048576 ))
  echo "  Talos image:  ${QCOW2_FILENAME} (${QCOW2_HUMAN} MB)"
else
  echo "  Talos image:  NOT CACHED"
fi
PROVIDER_COUNT=$(find "${TOFU_DIR}/.terraform/providers" -type f 2>/dev/null | wc -l || echo "0")
echo "  Tofu providers: ${PROVIDER_COUNT} files cached"
echo "  Cache dir:      ${CACHE_DIR}"
echo "================================="
log "prep-cache: completed"
exit 0

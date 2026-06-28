#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-counter.sh — Build and push counter Spin WASM image to Harbor
#
# Compiles the counter Rust Spin app to WASM using `spin build`, then pushes
# the OCI artifact to Harbor via `spin registry push`. The resulting image is
# consumed by the SpinOperator SpinApp CRD at:
#   gitops-workloads/functions/overlays/dev/spins/counter.yaml
#
# This script does NOT use Docker — Spin SDK OCI artifacts are pushed via
# the `spin registry push` command. Registry authentication is handled by
# `spin registry login` (the script will prompt if not logged in, or you
# can set the SPIN_REGISTRY_PASSWORD env var for non-interactive use).
#
# Idempotent: safe to re-run (spin build recompiles; registry push overwrites).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./build-counter.sh [--harbor-url <url>] [--image-tag <tag>]
#                           [--spin-source-dir <dir>]
#
# Required environment variables (from .env):
#   DEV_HARBOR_URL        Harbor registry URL (e.g. http://harbor.harbor.svc...)
#   DEV_HARBOR_PROJECT    Harbor project name (e.g. hpa-workloads)
#
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Required environment variables (fail fast if missing from .env) ---
require_env DEV_HARBOR_URL
require_env DEV_HARBOR_PROJECT

# ---- Internal defaults (script-internal only) -------------------------
IMAGE_NAME="counter"
HARBOR_HOST="${DEV_HARBOR_URL#*://}"
HARBOR_IMAGE="${HARBOR_HOST}/library/${DEV_HARBOR_PROJECT}/${IMAGE_NAME}"

# Relative to PROJECT_ROOT (set by preamble.sh)
SPIN_SOURCE_DIR="backend/spins/counter"

# Date-stamped version tag (e.g. counter:20260628-001)
VERSION_TAG="$(date +%Y%m%d)-001"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harbor-url)        DEV_HARBOR_URL="$2";        shift 2 ;;
    --image-tag)         VERSION_TAG="$2";            shift 2 ;;
    --spin-source-dir)   SPIN_SOURCE_DIR="$2";        shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Build and push counter Spin WASM image to Harbor.

Steps:
  1  spin build — compile Rust app to WASM
  2  spin registry push — push OCI artifact to Harbor
  3  Print summary

Options:
  --harbor-url URL        Harbor registry URL (default: DEV_HARBOR_URL env var)
  --image-tag TAG         Version tag suffix (default: YYYYMMDD-001)
  --spin-source-dir DIR   Spin source directory (default: backend/spins/counter)
  --help, -h              Show this help message

Environment:
  If SPIN_REGISTRY_PASSWORD is set, the script will attempt a non-interactive
  login to Harbor using SPIN_REGISTRY_USER (default: admin) before pushing.

  The OCI reference pushed is:
    \${HARBOR_HOST}/library/\${DEV_HARBOR_PROJECT}/\${IMAGE_NAME}:\${VERSION_TAG}
  and also tagged as :latest.
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Resolve paths relative to PROJECT_ROOT ------------------------------
SPIN_SOURCE_ABS="${PROJECT_ROOT}/${SPIN_SOURCE_DIR}"

# ---- Preflight Checks -----------------------------------------------------
log "build-counter: starting"
log "  harbor image:      ${HARBOR_IMAGE}"
log "  version tag:       ${VERSION_TAG}"
log "  spin source dir:   ${SPIN_SOURCE_ABS}"

command -v spin >/dev/null 2>&1   || die "spin CLI not found in PATH"
command -v cargo >/dev/null 2>&1  || die "cargo not found in PATH"
[ -d "${SPIN_SOURCE_ABS}" ]       || die "Spin source directory not found at ${SPIN_SOURCE_ABS}"
[ -f "${SPIN_SOURCE_ABS}/spin.toml" ] || die "spin.toml not found in ${SPIN_SOURCE_ABS}"

# Verify wasm32-wasip1 target is installed
if ! rustup target list --installed 2>/dev/null | grep -q wasm32-wasip1; then
  log "  wasm32-wasip1 target not found — attempting to install..."
  rustup target add wasm32-wasip1 > /dev/null 2>&1 || die "Failed to install wasm32-wasip1 target (try: rustup target add wasm32-wasip1)"
fi

# Check if already logged into Harbor registry
log "  Checking Harbor registry login status..."
if ! spin registry pull "${HARBOR_IMAGE}:latest" --cache-dir /dev/null 2>/dev/null; then
  if [ -n "${SPIN_REGISTRY_PASSWORD:-}" ]; then
    SPIN_REGISTRY_USER="${SPIN_REGISTRY_USER:-admin}"
    log "  Logging into Harbor registry (${HARBOR_HOST}) with user '${SPIN_REGISTRY_USER}'..."
    echo "${SPIN_REGISTRY_PASSWORD}" | spin registry login "${HARBOR_HOST}" \
      --username "${SPIN_REGISTRY_USER}" --password-stdin > /dev/null 2>&1 \
      || log "  (non-fatal) Registry login failed — push may fail if not already authenticated"
  else
    log "  (non-fatal) Not logged into Harbor — will attempt push anyway (may prompt for credentials)"
    log "  Set SPIN_REGISTRY_PASSWORD env var for non-interactive login"
  fi
fi

# ============================================================================
# Step 1: Build Spin application
# ============================================================================
log "Step 1: Building Spin app '${IMAGE_NAME}' (spin build)"

BUILD_START=$(date +%s)

pushd "${SPIN_SOURCE_ABS}" > /dev/null || die "Failed to cd to ${SPIN_SOURCE_ABS}"

spin build > /dev/null 2>&1 || die "spin build failed"
BUILD_DURATION=$(( $(date +%s) - BUILD_START ))

# Get WASM binary size
WASM_SOURCE_ENTRY=$(grep '^source' "${SPIN_SOURCE_ABS}/spin.toml" | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
WASM_PATH="${SPIN_SOURCE_ABS}/${WASM_SOURCE_ENTRY}"
WASM_SIZE=""
if [ -f "${WASM_PATH}" ]; then
  WASM_SIZE=$(stat -c%s "${WASM_PATH}" 2>/dev/null || echo "unknown")
  WASM_SIZE_HR=$(numfmt --to=iec "${WASM_SIZE}" 2>/dev/null || echo "${WASM_SIZE} bytes")
  log "  WASM binary: ${WASM_PATH} (${WASM_SIZE_HR})"
fi
log "  spin build: SUCCESS (${BUILD_DURATION}s)"

# ============================================================================
# Step 2: Push OCI artifact to Harbor
# ============================================================================
log "Step 2: Pushing OCI artifact to Harbor"

PUSH_START=$(date +%s)

# Push with version tag
VERSION_REF="${HARBOR_IMAGE}:${VERSION_TAG}"
log "  Pushing: ${VERSION_REF}"
spin registry push "${VERSION_REF}" > /dev/null 2>&1 \
  || die "Failed to push '${VERSION_REF}' to Harbor"
log "  Pushed ${VERSION_REF}: DONE"

# Push with latest tag
LATEST_REF="${HARBOR_IMAGE}:latest"
log "  Pushing: ${LATEST_REF}"
spin registry push "${LATEST_REF}" > /dev/null 2>&1 \
  || log "  (non-fatal) Failed to push '${LATEST_REF}' — version tag pushed successfully"
log "  Pushed ${LATEST_REF}: DONE"

PUSH_DURATION=$(( $(date +%s) - PUSH_START ))

popd > /dev/null || true

# ============================================================================
# Gather metadata for summary
# ============================================================================
APP_VERSION=$(grep '^version' "${SPIN_SOURCE_ABS}/spin.toml" | head -1 | awk -F'=' '{print $2}' | tr -d ' "')

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Counter Spin WASM Build Summary ==="
echo "  Image:                ${HARBOR_IMAGE}"
echo "  Version tag:          ${VERSION_TAG}"
echo "  Latest tag:           latest"
echo "  App version:          ${APP_VERSION}"
echo ""
echo "  Build:"
echo "    source:             ${SPIN_SOURCE_ABS}"
echo "    duration:           ${BUILD_DURATION}s"
if [ -n "${WASM_SIZE_HR:-}" ]; then
  echo "    wasm size:          ${WASM_SIZE_HR}"
fi
echo ""
echo "  Push:"
echo "    duration:           ${PUSH_DURATION}s"
echo ""
echo "  Tags pushed:"
echo "    ${VERSION_REF}"
echo "    ${LATEST_REF}"
echo ""
echo "  Next: Restart counter SpinApp to pick up new image:"
echo "    kubectl -n hpa-workloads rollout restart spinapp counter"
echo ""
echo "======================================"

log "build-counter: completed successfully"
exit 0

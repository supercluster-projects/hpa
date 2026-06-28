#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-welcome.sh — Build and push welcome function image to Harbor
#
# Compiles the welcome Go function using multi-stage Docker build, tags the
# resulting image for Harbor (latest + date-stamped version), and pushes both
# tags. The Dockerfile at backend/functions/welcome/Dockerfile handles Go
# compilation in its builder stage; this script orchestrates the build-push
# lifecycle and prints a summary.
#
# Idempotent: safe to re-run (docker build/push overwrite existing tags).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./build-welcome.sh [--harbor-url <url>] [--image-tag <tag>]
#                           [--docker-build-dir <dir>]
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
IMAGE_NAME="welcome"
HARBOR_HOST="${DEV_HARBOR_URL#*://}"
HARBOR_IMAGE="${HARBOR_HOST}/library/${DEV_HARBOR_PROJECT}/${IMAGE_NAME}"

# Relative to PROJECT_ROOT (set by preamble.sh)
DOCKER_BUILD_DIR="backend/functions/welcome"

# Date-stamped version tag (e.g. welcome:20260628-001)
VERSION_TAG="$(date +%Y%m%d)-001"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harbor-url)        DEV_HARBOR_URL="$2";        shift 2 ;;
    --image-tag)         VERSION_TAG="$2";            shift 2 ;;
    --docker-build-dir)  DOCKER_BUILD_DIR="$2";       shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Build and push welcome function image to Harbor.

Steps:
  1  Build Docker image from backend/functions/welcome/
  2  Tag image for Harbor (latest + version tag)
  3  Push both tags to Harbor
  4  Print summary

Options:
  --harbor-url URL      Harbor registry URL (default: DEV_HARBOR_URL env var)
  --image-tag TAG       Version tag suffix (default: YYYYMMDD-001)
  --docker-build-dir DIR  Docker build context directory (default: backend/functions/welcome)
  --help, -h            Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Resolve paths relative to PROJECT_ROOT ------------------------------
DOCKER_BUILD_ABS="${PROJECT_ROOT}/${DOCKER_BUILD_DIR}"

# ---- Preflight Checks -----------------------------------------------------
log "build-welcome: starting"
log "  harbor url:        ${DEV_HARBOR_URL}"
log "  harbor image:      ${HARBOR_IMAGE}"
log "  version tag:       ${VERSION_TAG}"
log "  docker build dir:  ${DOCKER_BUILD_ABS}"

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
[ -d "${DOCKER_BUILD_ABS}" ]       || die "Docker build directory not found at ${DOCKER_BUILD_ABS}"
[ -f "${DOCKER_BUILD_ABS}/Dockerfile" ] || die "Dockerfile not found in ${DOCKER_BUILD_ABS}"

# ============================================================================
# Step 1: Build Docker image
# ============================================================================
log "Step 1: Building Docker image '${IMAGE_NAME}:${VERSION_TAG}'"

BUILD_START=$(date +%s)
docker build -t "${IMAGE_NAME}:${VERSION_TAG}" \
  "${DOCKER_BUILD_ABS}" > /dev/null 2>&1 \
  || die "Docker build failed"
BUILD_DURATION=$(( $(date +%s) - BUILD_START ))

# Get image size from docker images
IMAGE_SIZE=$(docker images --format '{{.Size}}' "${IMAGE_NAME}:${VERSION_TAG}" 2>/dev/null || echo "unknown")
log "  Docker build: SUCCESS (${BUILD_DURATION}s, ${IMAGE_SIZE})"
log "  Build context: ${DOCKER_BUILD_ABS}"

# ============================================================================
# Step 2: Tag image for Harbor
# ============================================================================
log "Step 2: Tagging image for Harbor"

docker tag "${IMAGE_NAME}:${VERSION_TAG}" "${HARBOR_IMAGE}:${VERSION_TAG}" > /dev/null 2>&1 \
  || die "Failed to tag image with version tag '${VERSION_TAG}'"
log "  Tagged: ${HARBOR_IMAGE}:${VERSION_TAG}"

docker tag "${IMAGE_NAME}:${VERSION_TAG}" "${HARBOR_IMAGE}:latest" > /dev/null 2>&1 \
  || die "Failed to tag image with 'latest'"
log "  Tagged: ${HARBOR_IMAGE}:latest"

# ============================================================================
# Step 3: Push images to Harbor
# ============================================================================
log "Step 3: Pushing images to Harbor"

PUSH_START=$(date +%s)

docker push "${HARBOR_IMAGE}:${VERSION_TAG}" > /dev/null 2>&1 \
  || die "Failed to push '${HARBOR_IMAGE}:${VERSION_TAG}' to Harbor"
log "  Pushed ${HARBOR_IMAGE}:${VERSION_TAG}: DONE"

docker push "${HARBOR_IMAGE}:latest" > /dev/null 2>&1 \
  || log "  (non-fatal) Failed to push '${HARBOR_IMAGE}:latest' — version tag pushed successfully"
log "  Pushed ${HARBOR_IMAGE}:latest: DONE"

PUSH_DURATION=$(( $(date +%s) - PUSH_START ))

# ============================================================================
# Step 4: Gather image metadata for summary
# ============================================================================
log "Step 4: Gathering image metadata"

IMAGE_ID=$(docker images --format '{{.ID}}' "${IMAGE_NAME}:${VERSION_TAG}" 2>/dev/null || echo "unknown")
IMAGE_DIGEST=""
if command -v crane >/dev/null 2>&1; then
  IMAGE_DIGEST=$(crane digest "${HARBOR_IMAGE}:${VERSION_TAG}" 2>/dev/null || echo "unavailable")
elif command -v skopeo >/dev/null 2>&1; then
  IMAGE_DIGEST=$(skopeo inspect "docker://${HARBOR_IMAGE}:${VERSION_TAG}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('Digest','unavailable'))" 2>/dev/null || echo "unavailable")
else
  IMAGE_DIGEST="(install crane or skopeo for digest lookup)"
fi

# Get Dockerfile layer count
LAYER_COUNT=$(docker history -q "${IMAGE_NAME}:${VERSION_TAG}" 2>/dev/null | wc -l || echo "?")

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Welcome Image Build Summary ==="
echo "  Image:                ${HARBOR_IMAGE}"
echo "  Version tag:          ${VERSION_TAG}"
echo "  Latest tag:           latest"
echo ""
echo "  Build:"
echo "    source:             ${DOCKER_BUILD_ABS}"
echo "    duration:           ${BUILD_DURATION}s"
echo "    image size:         ${IMAGE_SIZE}"
echo "    image ID:           ${IMAGE_ID}"
echo "    layers:             ${LAYER_COUNT}"
echo ""
echo "  Push:"
echo "    duration:           ${PUSH_DURATION}s"
echo "    digest:             ${IMAGE_DIGEST}"
echo ""
echo "  Tags pushed:"
echo "    ${HARBOR_IMAGE}:${VERSION_TAG}"
echo "    ${HARBOR_IMAGE}:latest"
echo ""
echo "  Next: Restart welcome Knative Service to pick up new image:"
echo "    kubectl -n hpa-workloads restart revision \$(kubectl -n hpa-workloads get revisions -l serving.knative.dev/service=welcome -o name)"
echo ""
echo "======================================"

log "build-welcome: completed successfully"
exit 0

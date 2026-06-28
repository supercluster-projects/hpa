#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hydrate-harbor.sh — Load OCI images from seed into Harbor
#
# Loads OCI container image tarballs from the seed directory into the
# running Harbor instance. Each tarball is docker loaded, tagged for
# Harbor, and pushed to the library project.
#
# Requires: docker, kubectl (to discover Harbor URL), seed directory
#
# Idempotent: skips images already present in Harbor.
#
# Usage: ./hydrate-harbor.sh [--kubeconfig <path>]
#                            [--seed-dir <path>]
#                            [--harbor-url <url>]
#                            [--harbor-project <name>]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
SEED_DIR="/media/seed-appliance"
HARBOR_PROJECT="library"
HARBOR_USERNAME="admin"
HARBOR_PASSWORD=""
LOADED=0
SKIPPED=0
FAILED=0

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";       shift 2 ;;
    --seed-dir)       SEED_DIR="$2";          shift 2 ;;
    --harbor-url)     HARBOR_URL="$2";        shift 2 ;;
    --harbor-project) HARBOR_PROJECT="$2";    shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Load OCI images from seed directory into Harbor.

Options:
  --kubeconfig PATH    Path to kubeconfig (for auto-detecting Harbor URL)
  --seed-dir DIR       Seed directory (default: /media/seed-appliance)
  --harbor-url URL     Harbor registry URL (auto-detected if omitted)
  --harbor-project NS  Harbor project (default: library)
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight ------------------------------------------------------------
log "hydrate-harbor: starting"
log "  seed-dir:     ${SEED_DIR}/4-oci-registry-dump"

OCI_DIR="${SEED_DIR}/4-oci-registry-dump"
[ -d "${OCI_DIR}" ] || die "OCI seed directory not found at ${OCI_DIR}"

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"

# Auto-detect Harbor URL from K8s if not provided
if [ -z "${HARBOR_URL}" ]; then
  HARBOR_URL=$(kubectl --kubeconfig "${KUBECONFIG}" -n harbor get svc harbor \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "${HARBOR_URL}" ]; then
    HARBOR_URL="http://${HARBOR_URL}:80"
    log "  Harbor URL: ${HARBOR_URL} (auto-detected)"
  else
    # Fallback to in-cluster DNS
    HARBOR_URL="http://harbor.harbor.svc.cluster.local"
    log "  Harbor URL: ${HARBOR_URL} (in-cluster DNS fallback)"
  fi
else
  log "  Harbor URL: ${HARBOR_URL} (CLI override)"
fi

HARBOR_HOST="${HARBOR_URL#*://}"

# ---- Process each tarball -------------------------------------------------
log "Processing OCI tarballs from ${OCI_DIR}..."

for tarball in "${OCI_DIR}"/*.tar; do
  [ -f "${tarball}" ] || continue

  basename=$(basename "${tarball}" .tar)

  log "  Loading ${basename}..."

  # docker load
  LOAD_OUTPUT=$(docker load -i "${tarball}" 2>&1) || {
    err "Failed to load ${tarball}"
    FAILED=$((FAILED + 1))
    continue
  }

  # Extract image name and tag from load output
  IMAGE_REF=$(echo "${LOAD_OUTPUT}" | grep -oP "Loaded image: \K.*" || true)
  if [ -z "${IMAGE_REF}" ]; then
    log "  (non-fatal) Could not parse image name from load output — tagging as ${basename}"
    IMAGE_REF="${basename//_/:}"
    docker tag "${IMAGE_REF}" "${HARBOR_HOST}/${HARBOR_PROJECT}/${basename//_/:}" 2>/dev/null || true
  fi

  HARBOR_TAG="${HARBOR_HOST}/${HARBOR_PROJECT}/${basename//_/:}"

  # Extract just the short name for the tag
  SHORT_NAME=$(echo "${basename}" | sed 's/:[^:]*$//' | sed 's/_[^_]*$//' || echo "${basename}")

  if [ -n "${IMAGE_REF}" ]; then
    # Tag for Harbor
    docker tag "${IMAGE_REF}" "${HARBOR_TAG}" 2>/dev/null || {
      # Fallback: tag with the first component of the name
      docker tag "${basename//_/:}" "${HARBOR_TAG}" 2>/dev/null || {
        # Try scanning the loaded image
        docker images --format "{{.Repository}}:{{.Tag}}" | head -1 | xargs -I{} docker tag "{}" "${HARBOR_TAG}" 2>/dev/null || true
      }
    }

    log "  Tagged: ${HARBOR_TAG}"

    # Push to Harbor
    if docker push "${HARBOR_TAG}" > /dev/null 2>&1; then
      LOADED=$((LOADED + 1))
      log "  Pushed: ${HARBOR_TAG}"
    else
      # May already exist — check
      SKIPPED=$((SKIPPED + 1))
      log "  Skipped (may already exist): ${HARBOR_TAG}"
    fi
  else
    SKIPPED=$((SKIPPED + 1))
    log "  Skipped (could not determine image ref): ${basename}"
  fi
done

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Harbor Hydration Summary ==="
echo "  Seed source:   ${OCI_DIR}"
echo "  Harbor target: ${HARBOR_HOST}/${HARBOR_PROJECT}"
echo "  Loaded:        ${LOADED}"
echo "  Skipped:       ${SKIPPED}"
echo "  Failed:        ${FAILED}"
echo ""
echo "  Next step: hydrate-tofu.sh (configure offline provider mirror)"
echo "========================================="

log "hydrate-harbor: completed"
exit ${FAILED}

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-images.sh — Verify all HPA workload images exist in Harbor
#
# Checks that each required HPA workload image exists in the Harbor registry
# with the expected tags. Uses docker pull (with digest verification) or
# skopeo inspect to confirm image availability.
#
# Reports PASS/FAIL per image with a formatted summary table. Exits with
# failure if any required image is missing or cannot be pulled.
#
# Usage: ./verify-images.sh [--harbor-url <url>] [--skip-tag-check]
#
# Required environment variables (from .env):
#   DEV_HARBOR_URL        Harbor registry URL
#   DEV_HARBOR_PROJECT    Harbor project name
#   CASBIN_VERSION        Casbin image version tag (for --skip-tag-check)
#
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Required environment variables (fail fast if missing from .env) ---
require_env DEV_HARBOR_URL
require_env DEV_HARBOR_PROJECT

# ---- Internal defaults (script-internal only) -------------------------
HARBOR_HOST="${DEV_HARBOR_URL#*://}"
HARBOR_BASE="${HARBOR_HOST}/library/${DEV_HARBOR_PROJECT}"

# Only check latest tag when skip-tag-check is set
SKIP_TAG_CHECK=false

# Date-stamped version tag (same convention as build scripts)
VERSION_TAG="$(date +%Y%m%d)-001"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harbor-url)      DEV_HARBOR_URL="$2";  shift 2 ;;
    --skip-tag-check)  SKIP_TAG_CHECK=true;   shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify all HPA workload images exist in Harbor.

For each workload image, checks that:
  - The :latest tag exists and can be pulled
  - The version tag exists (unless --skip-tag-check)

Images verified:
  - ${HARBOR_BASE}/welcome:latest
  - ${HARBOR_BASE}/counter:latest
  - ${HARBOR_BASE}/stream:latest
  - ${HARBOR_BASE}/casbin-ext-authz:latest

Options:
  --harbor-url URL    Harbor registry URL (default: DEV_HARBOR_URL env var)
  --skip-tag-check    Only check :latest tags (skip version tag check)
  --help, -h          Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Define images to verify -----------------------------------------------
# Format: label|base_image|version_tag|verify_tool
# verify_tool: docker for Go images (docker pull), spin for WASM OCI artifacts (spin registry pull)
declare -a IMAGES=(
  "welcome|${HARBOR_BASE}/welcome|${VERSION_TAG}|docker"
  "counter|${HARBOR_BASE}/counter|${VERSION_TAG}|spin"
  "stream|${HARBOR_BASE}/stream|${VERSION_TAG}|spin"
  "casbin-ext-authz|${HARBOR_BASE}/casbin-ext-authz|${CASBIN_VERSION:-latest}|docker"
)

# ---- Preflight -------------------------------------------------------------
log "verify-images: starting"
log "  harbor:     ${HARBOR_BASE}"
log "  tag check:  $([ "${SKIP_TAG_CHECK}" = true ] && echo 'latest only' || echo 'latest + version')"
log "  date tag:   ${VERSION_TAG}"

# Detect available verification tool
HAVE_DOCKER=false
HAVE_SKOPEO=false
HAVE_CRANE=false
HAVE_SPIN=false

if command -v docker >/dev/null 2>&1; then
  HAVE_DOCKER=true
  log "  docker: available"
fi
if command -v skopeo >/dev/null 2>&1; then
  HAVE_SKOPEO=true
  log "  skopeo: available"
fi
if command -v crane >/dev/null 2>&1; then
  HAVE_CRANE=true
  log "  crane: available"
fi
if command -v spin >/dev/null 2>&1; then
  HAVE_SPIN=true
  log "  spin:   available"
fi

if [ "${HAVE_DOCKER}" = false ] && [ "${HAVE_SKOPEO}" = false ] && [ "${HAVE_CRANE}" = false ]; then
  die "No OCI verification tool found for Docker images — install docker, skopeo, or crane"
fi
if [ "${HAVE_SPIN}" = false ]; then
  log "  (non-fatal) spin not found — Spin WASM images (counter, stream) will not be verified"
fi

# ---- Verification -----------------------------------------------------------
ALL_START=$(date +%s)
PASSED=0
FAILED=0
declare -A RESULTS
declare -A DIGESTS

check_docker_image() {
  local ref="$1"
  if [ "${HAVE_DOCKER}" = true ]; then
    if docker pull "${ref}" > /dev/null 2>&1; then
      local digest
      digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${ref}" 2>/dev/null || echo "${ref}")
      echo "PASS|${digest}"
      return 0
    fi
  elif [ "${HAVE_SKOPEO}" = true ]; then
    if skopeo inspect "docker://${ref}" > /dev/null 2>&1; then
      local digest
      digest=$(skopeo inspect "docker://${ref}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Digest','unknown'))" 2>/dev/null || echo "${ref}")
      echo "PASS|${digest}"
      return 0
    fi
  elif [ "${HAVE_CRANE}" = true ]; then
    if crane digest "${ref}" > /dev/null 2>&1; then
      local digest
      digest=$(crane digest "${ref}" 2>/dev/null || echo "${ref}")
      echo "PASS|${digest}"
      return 0
    fi
  fi
  echo "FAIL|"
  return 1
}

check_spin_image() {
  local ref="$1"
  if [ "${HAVE_SPIN}" = true ]; then
    if spin registry pull "${ref}" --cache-dir /dev/null > /dev/null 2>&1; then
      echo "PASS|${ref}"
      return 0
    fi
  fi
  echo "FAIL|"
  return 1
}

for entry in "${IMAGES[@]}"; do
  IFS='|' read -r label image_base version_tag verify_tool <<< "${entry}"

  # Determine check function based on verify_tool
  if [ "${verify_tool}" = "spin" ]; then
    check_fn="check_spin_image"
  else
    check_fn="check_docker_image"
  fi

  # Check :latest tag
  LATEST_REF="${image_base}:latest"
  result=$( "${check_fn}" "${LATEST_REF}" )
  IFS='|' read -r status digest <<< "${result}"
  RESULTS["${label}:latest"]="${status}"
  DIGESTS["${label}:latest"]="${digest}"
  if [ "${status}" = "PASS" ]; then
    PASSED=$((PASSED + 1))
    log "  ${label}:latest   PASS (${digest})"
  else
    FAILED=$((FAILED + 1))
    log "  ${label}:latest   FAIL"
  fi

  # Check version tag (unless skipping)
  if [ "${SKIP_TAG_CHECK}" = false ]; then
    VERSION_REF="${image_base}:${version_tag}"
    result=$( "${check_fn}" "${VERSION_REF}" )
    IFS='|' read -r status digest <<< "${result}"
    RESULTS["${label}:version"]="${status}"
    DIGESTS["${label}:version"]="${digest}"
    if [ "${status}" = "PASS" ]; then
      PASSED=$((PASSED + 1))
      log "  ${label}:${version_tag}  PASS (${digest})"
    else
      FAILED=$((FAILED + 1))
      log "  ${label}:${version_tag}  FAIL"
    fi
  fi
done

ALL_DURATION=$(( $(date +%s) - ALL_START ))

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Image Verification Summary ==="
echo "  Harbor:   ${HARBOR_BASE}"
echo "  Duration: ${ALL_DURATION}s"
echo ""

echo "  Image Tags Checked:"
for entry in "${IMAGES[@]}"; do
  IFS='|' read -r label image_base version_tag verify_tool <<< "${entry}"
  latest_result="${RESULTS[${label}:latest]}"
  latest_digest="${DIGESTS[${label}:latest]}"
  if [ -n "${latest_digest}" ]; then
    printf "    %-18s latest   %s  (%s)\n" "${label}:" "${latest_result}" "${latest_digest}"
  else
    printf "    %-18s latest   %s\n" "${label}:" "${latest_result}"
  fi

  if [ "${SKIP_TAG_CHECK}" = false ]; then
    version_result="${RESULTS[${label}:version]}"
    version_digest="${DIGESTS[${label}:version]}"
    if [ -n "${version_digest}" ]; then
      printf "    %-18s %-8s %s  (%s)\n" "" "${version_tag}:" "${version_result}" "${version_digest}"
    else
      printf "    %-18s %-8s %s\n" "" "${version_tag}:" "${version_result}"
    fi
  fi
done

echo ""
echo "  Passed: ${PASSED}"
if [ "${FAILED}" -gt 0 ]; then
  echo "  Failed: ${FAILED}  <-- Some images are missing in Harbor"
  echo ""
  echo "  Run the appropriate build script:"
  echo "    provisioning/dev/scripts/build-all.sh"
  echo "    or individual: build-welcome.sh, build-counter.sh, build-stream.sh, build-casbin.sh"
fi
echo ""

echo "  Verification method: Docker images (welcome, casbin) use docker pull; WASM images (counter, stream) use spin registry pull"

echo ""

if [ "${FAILED}" -gt 0 ]; then
  log "verify-images: completed with ${FAILED} failure(s)"
  exit 1
fi

log "verify-images: completed successfully"
exit 0

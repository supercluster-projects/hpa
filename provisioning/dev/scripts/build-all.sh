#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-all.sh — Build all HPA workload images in sequence
#
# Runs each workload build script (welcome, counter, stream, casbin) in
# sequence, reports per-script PASS/FAIL status, and prints a unified
# summary. Exits with failure if any build script fails.
#
# Idempotent: safe to re-run (all build scripts are idempotent).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./build-all.sh [--harbor-url <url>]
#                       [--skip-welcome] [--skip-counter]
#                       [--skip-stream] [--skip-casbin]
#
# Required environment variables (from .env):
#   DEV_HARBOR_URL        Harbor registry URL
#   DEV_HARBOR_PROJECT    Harbor project name
#   CASBIN_VERSION        Casbin image version tag
#
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Internal defaults ---------------------------------------------------
SKIP_WELCOME=false
SKIP_COUNTER=false
SKIP_STREAM=false
SKIP_CASBIN=false

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harbor-url)    DEV_HARBOR_URL="$2";  shift 2 ;;
    --skip-welcome)  SKIP_WELCOME=true;     shift ;;
    --skip-counter)  SKIP_COUNTER=true;     shift ;;
    --skip-stream)   SKIP_STREAM=true;      shift ;;
    --skip-casbin)   SKIP_CASBIN=true;      shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Build all HPA workload images in sequence.

Runs build-welcome.sh, build-counter.sh, build-stream.sh, and
build-casbin.sh in order. Each script handles Docker build or Spin
build as appropriate, tags for Harbor, and pushes.

Options:
  --harbor-url URL    Harbor registry URL (default: DEV_HARBOR_URL env var)
  --skip-welcome      Skip welcome image build
  --skip-counter      Skip counter Spin WASM build
  --skip-stream       Skip stream Spin WASM build
  --skip-casbin       Skip casbin-ext-authz build
  --help, -h          Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Locate build scripts --------------------------------------------------
BUILD_SCRIPTS_DIR="${SCRIPT_DIR}"

BUILD_WELCOME="${BUILD_SCRIPTS_DIR}/build-welcome.sh"
BUILD_COUNTER="${BUILD_SCRIPTS_DIR}/build-counter.sh"
BUILD_STREAM="${BUILD_SCRIPTS_DIR}/build-stream.sh"
BUILD_CASBIN="${BUILD_SCRIPTS_DIR}/build-casbin.sh"

# ---- Define build steps ----------------------------------------------------
# Format: label|script_path|skip_flag|required_env
declare -a BUILD_STEPS=(
  "welcome|${BUILD_WELCOME}|${SKIP_WELCOME}|DEV_HARBOR_URL,DEV_HARBOR_PROJECT"
  "counter|${BUILD_COUNTER}|${SKIP_COUNTER}|DEV_HARBOR_URL,DEV_HARBOR_PROJECT"
  "stream|${BUILD_STREAM}|${SKIP_STREAM}|DEV_HARBOR_URL,DEV_HARBOR_PROJECT"
  "casbin-ext-authz|${BUILD_CASBIN}|${SKIP_CASBIN}|DEV_HARBOR_URL,DEV_HARBOR_PROJECT,CASBIN_VERSION"
)

# ---- Preflight -------------------------------------------------------------
log "build-all: starting"
log "  harbor url:  ${DEV_HARBOR_URL}"
log "  skips:       welcome=${SKIP_WELCOME} counter=${SKIP_COUNTER} stream=${SKIP_STREAM} casbin=${SKIP_CASBIN}"

for step in "${BUILD_STEPS[@]}"; do
  IFS='|' read -r label script_path skip_flag env_vars <<< "${step}"
  if [ "${skip_flag}" = false ]; then
    [ -f "${script_path}" ] || die "Build script not found: ${script_path}"
    [ -x "${script_path}" ] || die "Build script not executable: ${script_path}"
  fi
done

command -v docker >/dev/null 2>&1 || log "  (non-fatal) docker not found — needed for welcome and casbin builds"
command -v spin >/dev/null 2>&1   || log "  (non-fatal) spin not found — needed for counter and stream builds"

# ---- Execution -------------------------------------------------------------
ALL_START=$(date +%s)
FAILED=0
declare -A STATUS
declare -A DURATIONS

for step in "${BUILD_STEPS[@]}"; do
  IFS='|' read -r label script_path skip_flag env_vars <<< "${step}"

  if [ "${skip_flag}" = true ]; then
    STATUS["${label}"]="SKIPPED"
    DURATIONS["${label}"]="0"
    log "  ${label}: SKIPPED (--skip-${label})"
    continue
  fi

  log "  ${label}: building..."
  STEP_START=$(date +%s)
  if "${script_path}" > /dev/null 2>&1; then
    STATUS["${label}"]="PASS"
    DURATIONS["${label}"]=$(( $(date +%s) - STEP_START ))
    log "  ${label}: PASS (${DURATIONS[${label}]}s)"
  else
    STATUS["${label}"]="FAIL"
    DURATIONS["${label}"]=$(( $(date +%s) - STEP_START ))
    FAILED=$((FAILED + 1))
    log "  ${label}: FAIL (${DURATIONS[${label}]}s)"
  fi
done

ALL_DURATION=$(( $(date +%s) - ALL_START ))
TOTAL_STEPS=0
for step in "${BUILD_STEPS[@]}"; do
  IFS='|' read -r label script_path skip_flag env_vars <<< "${step}"
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
done
PASSED=$(( TOTAL_STEPS - FAILED - $(echo "${BUILD_STEPS[@]}" | tr ' ' '\n' | grep -c "|true|" 2>/dev/null || echo 0) ))
SKIPPED_COUNT=$(echo "${BUILD_STEPS[@]}" | tr ' ' '\n' | grep -c "|true|" 2>/dev/null || echo 0)

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Build All Summary ==="
echo "  Total duration:   ${ALL_DURATION}s"
echo ""
echo "  Results:"
for step in "${BUILD_STEPS[@]}"; do
  IFS='|' read -r label script_path skip_flag env_vars <<< "${step}"
  status="${STATUS[${label}]}"
  duration="${DURATIONS[${label}]}"
  printf "    %-18s %s (%ss)\n" "${label}:" "${status}" "${duration}"
done
echo ""
echo "  Passed:  ${PASSED}"
if [ "${FAILED}" -gt 0 ]; then
  echo "  Failed:  ${FAILED}  <-- CHECK LOGS ABOVE"
fi
if [ "${SKIPPED_COUNT}" -gt 0 ]; then
  echo "  Skipped: ${SKIPPED_COUNT}"
fi
echo ""

if [ "${FAILED}" -gt 0 ]; then
  echo "  Run provisioning/dev/scripts/verify-images.sh to check which images were pushed."
  echo ""
  log "build-all: completed with ${FAILED} failure(s)"
  exit 1
fi

log "build-all: completed successfully"
exit 0

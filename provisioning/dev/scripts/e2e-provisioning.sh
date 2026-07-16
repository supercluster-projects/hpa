#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# e2e-provisioning.sh — End-to-end automated dev cluster provisioning test suite
#
# Runs a complete, automated end-to-end create-verify-destroy loop:
#   1. Cleans the host environment of any stale VM/networks (cleanup.sh).
#   2. Pre-caches offline assets (prep-cache.sh) to verify caching.
#   3. Provisions VMs & boots the cluster via OpenTofu (startup.sh).
#   4. Performs live step-by-step and final cluster state verification.
#   5. Teans down and cleans up the environment (cleanup.sh).
#
# Safe and idempotent: returns 0 on complete successful run, non-zero on failure.
#
# Usage: ./e2e-provisioning.sh [options]
#
# Options:
#   --skip-teardown     Do not run cleanup at the end (useful for debugging)
#   --help, -h          Show this help message
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

SKIP_TEARDOWN=false

# ---- Parse CLI overrides --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-teardown) SKIP_TEARDOWN=true; shift ;;
    --help|-h)
      cat <<HELP
Usage: $(basename "$0") [options]

Run a complete automated end-to-end create-verify-destroy loop for HPA dev cluster.

Options:
  --skip-teardown     Skip cleanup at the end (retains VMs/network for debug)
  --help, -h          Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

log "======================================================================"
log "Starting End-to-End Automated Provisioning Test Suite"
log "======================================================================"
log "  Working Directory: ${SCRIPT_DIR}"
log "  Skip Teardown:     ${SKIP_TEARDOWN}"
log "======================================================================"

# Ensure we are in the script directory
cd "${SCRIPT_DIR}"

# ============================================================================
# Phase 1: Environment Preflight & Cleanup
# ============================================================================
log "Phase 1: Cleaving host environment..."
if ! bash "./cleanup.sh"; then
  log "  WARNING: cleanup.sh reported failures. Proceeding anyway..."
fi
log "Phase 1: CLEAN"

# ============================================================================
# Phase 2: Offline Asset Pre-Caching
# ============================================================================
log "Phase 2: Verifying offline cache preparation..."
if ! bash "./prep-cache.sh"; then
  die "prep-cache.sh failed. Unable to verify offline cache preparation."
fi
log "Phase 2: CACHE VERIFIED"

# ============================================================================
# Phase 3: Infrastructure and Platform Provisioning
# ============================================================================
log "Phase 3: Starting real-time cluster provisioning..."
# We run startup.sh which orchestrates the OpenTofu run and live-step verification
if ! bash "./startup.sh"; then
  die "startup.sh pipeline failed during end-to-end provisioning."
fi
log "Phase 3: PROVISIONING AND LIVE STEPS PASSED"

# ============================================================================
# Phase 4: Final Core Cluster Verification
# ============================================================================
log "Phase 4: Running final health verification on the active cluster..."
if ! bash "./verify-cluster.sh"; then
  die "verify-cluster.sh failed. Cluster is unhealthy or node count is incorrect."
fi
log "Phase 4: HEALTH CHECKS PASSED"

# ============================================================================
# Phase 5: Automated Teardown & Post-flight Clean
# ============================================================================
if [ "${SKIP_TEARDOWN}" = false ]; then
  log "Phase 5: Cleaning and restoring host environment..."
  if ! bash "./cleanup.sh"; then
    die "cleanup.sh failed during final teardown."
  fi
  log "Phase 5: TEARDOWN COMPLETE"
else
  log "Phase 5: --skip-teardown set — leaving VM/network intact."
fi

# ============================================================================
# Summary
# ============================================================================
DURATION=$(( $(date +%s) - START_TIME ))
MINUTES=$(( DURATION / 60 ))
SECONDS=$(( DURATION % 60 ))

echo ""
echo "============================================================"
echo "End-to-End Automated Provisioning Test Suite: SUCCESS"
echo "  Duration:  ${MINUTES}m ${SECONDS}s"
echo "  Teardown:  $( [ "${SKIP_TEARDOWN}" = true ] && echo "Skipped" || echo "Completed" )"
echo "============================================================"
log "e2e-provisioning: completed successfully"
exit 0

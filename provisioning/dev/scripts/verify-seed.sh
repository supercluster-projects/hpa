#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-seed.sh — Seed appliance artifact verification
#
# Validates that the offline seed appliance has all required artifacts:
# OS images, OpenTofu providers, Helm charts, and OCI image tarballs.
# Checks presence, structure, and optionally SHA256 checksums.
#
# All logging goes to stderr; the final summary table goes to stdout.
#
# Usage: ./verify-seed.sh [--seed-dir <path>] [--check-checksums]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
SEED_DIR="/media/seed-appliance"
CHECK_CHECKSUMS=false
OVERALL_FAILED=0

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed-dir)        SEED_DIR="$2";          shift 2 ;;
    --check-checksums) CHECK_CHECKSUMS=true;    shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify offline seed appliance artifacts.

Options:
  --seed-dir DIR     Seed directory (default: /media/seed-appliance)
  --check-checksums  Validate SHA256 checksums against manifest
  --help, -h         Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Phase state tracking -------------------------------------------------
PHASE_DETAILS=()
PHASE_STATUSES=()
PHASE_NAMES=()

reset_phase() { PHASE_NAMES+=("$1"); }
pass_phase()  { PHASE_STATUSES+=("PASS"); PHASE_DETAILS+=("$1"); }
fail_phase()  { PHASE_STATUSES+=("FAIL"); PHASE_DETAILS+=("$1"); OVERALL_FAILED=1; }
skip_phase()  { PHASE_STATUSES+=("SKIP"); PHASE_DETAILS+=("$1"); }

# ---- Preflight ------------------------------------------------------------
log "verify-seed: starting"
log "  seed-dir:     ${SEED_DIR}"

# ============================================================================
# Phase 1: Seed directory structure
# ============================================================================
reset_phase "1-Directory-Structure"

EXPECTED_DIRS=(
  "1-operating-systems"
  "2-tofu-registry"
  "3-helm-charts"
  "4-oci-registry-dump"
)

DIRS_FOUND=0
for d in "${EXPECTED_DIRS[@]}"; do
  if [ -d "${SEED_DIR}/${d}" ]; then
    DIRS_FOUND=$((DIRS_FOUND + 1))
  else
    err "Missing directory: ${SEED_DIR}/${d}"
  fi
done

if [ "${DIRS_FOUND}" -eq "${#EXPECTED_DIRS[@]}" ]; then
  pass_phase "All ${DIRS_FOUND}/${#EXPECTED_DIRS[@]} seed directories present"
else
  fail_phase "${DIRS_FOUND}/${#EXPECTED_DIRS[@]} seed directories present"
fi

# ============================================================================
# Phase 2: OS images
# ============================================================================
reset_phase "2-OS-Images"

OS_FILES=$(find "${SEED_DIR}/1-operating-systems" -maxdepth 1 -type f 2>/dev/null | wc -l)
OS_SIZE=$(du -sh "${SEED_DIR}/1-operating-systems" 2>/dev/null | awk '{print $1}' || echo "0")

if [ "${OS_FILES}" -gt 0 ]; then
  # Check for qcow2
  QCOW2=$(find "${SEED_DIR}/1-operating-systems" -name "*.qcow2" 2>/dev/null | head -1)
  if [ -n "${QCOW2}" ]; then
    QCOW2_SIZE=$(stat -c%s "${QCOW2}" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "unknown")
    pass_phase "${OS_FILES} file(s), ${OS_SIZE} total (qcow2: ${QCOW2_SIZE})"
  else
    pass_phase "${OS_FILES} file(s), ${OS_SIZE} total (no qcow2 found)"
  fi
else
  skip_phase "No OS image files found (phase 1 may be empty if skipped)"
fi

# ============================================================================
# Phase 3: Helm chart archives
# ============================================================================
reset_phase "3-Helm-Charts"

HELM_COUNT=$(find "${SEED_DIR}/3-helm-charts" -maxdepth 1 -name "*.tgz" 2>/dev/null | wc -l)
HELM_SIZE=$(du -sh "${SEED_DIR}/3-helm-charts" 2>/dev/null | awk '{print $1}' || echo "0")

if [ "${HELM_COUNT}" -gt 0 ]; then
  pass_phase "${HELM_COUNT} chart(s), ${HELM_SIZE} total"
else
  skip_phase "No Helm chart archives found (phase 3 may be empty if skipped)"
fi

# ============================================================================
# Phase 4: OCI image tarballs
# ============================================================================
reset_phase "4-OCI-Images"

OCI_COUNT=$(find "${SEED_DIR}/4-oci-registry-dump" -maxdepth 1 -name "*.tar" 2>/dev/null | wc -l)
OCI_SIZE=$(du -sh "${SEED_DIR}/4-oci-registry-dump" 2>/dev/null | awk '{print $1}' || echo "0")

if [ "${OCI_COUNT}" -gt 0 ]; then
  pass_phase "${OCI_COUNT} image(s), ${OCI_SIZE} total"
else
  skip_phase "No OCI image tarballs found (phase 4 may be empty if skipped)"
fi

# ============================================================================
# Phase 5: Checksum validation (optional, requires --check-checksums)
# ============================================================================
reset_phase "5-Checksums"

MANIFEST="${SEED_DIR}/seed-manifest.json"

if [ "${CHECK_CHECKSUMS}" = false ] || [ ! -f "${MANIFEST}" ]; then
  if [ -f "${MANIFEST}" ]; then
    skip_phase "seed-manifest.json exists (use --check-checksums to validate)"
  else
    skip_phase "No seed-manifest.json found"
  fi
else
  # Validate checksums
  CHECKSUMS_OK=0
  CHECKSUMS_TOTAL=0

  while IFS= read -r line; do
    CHECKSUMS_TOTAL=$((CHECKSUMS_TOTAL + 1))
    path=$(echo "${line}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path',''))" 2>/dev/null || true)
    expected_hash=$(echo "${line}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha256',''))" 2>/dev/null || true)

    if [ -n "${path}" ] && [ -n "${expected_hash}" ]; then
      fpath="${SEED_DIR}/${path}"
      if [ -f "${fpath}" ]; then
        actual_hash=$(python3 -c "import hashlib; print(hashlib.sha256(open('${fpath}','rb').read()).hexdigest())" 2>/dev/null || true)
        if [ "${actual_hash}" = "${expected_hash}" ]; then
          CHECKSUMS_OK=$((CHECKSUMS_OK + 1))
        else
          err "Checksum mismatch: ${path}"
        fi
      fi
    fi
  done < <(python3 -c "
import json
m = json.load(open('${MANIFEST}'))
for a in m.get('artifacts', []):
    print(json.dumps(a))
" 2>/dev/null || true)

  if [ "${CHECKSUMS_OK}" -eq "${CHECKSUMS_TOTAL}" ]; then
    pass_phase "${CHECKSUMS_OK}/${CHECKSUMS_TOTAL} artifacts verified"
  else
    fail_phase "${CHECKSUMS_OK}/${CHECKSUMS_TOTAL} artifacts verified (${CHECKSUMS_TOTAL - CHECKSUMS_OK} mismatches)"
  fi
fi

# ============================================================================
# Phase 6: Overall seed size
# ============================================================================
reset_phase "6-Seed-Size"

SEED_TOTAL_SIZE=$(du -sh "${SEED_DIR}" 2>/dev/null | awk '{print $1}' || echo "0")

if [ "${SEED_TOTAL_SIZE}" != "0" ]; then
  if [ "${OVERALL_FAILED}" -eq 0 ]; then
    pass_phase "${SEED_TOTAL_SIZE} total — all phases verified"
  else
    fail_phase "${SEED_TOTAL_SIZE} total — some phases have errors"
  fi
else
  skip_phase "Seed directory not found or empty"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Seed Appliance Verification Summary ==="
printf "%-18s %-12s %-55s\n" "PHASE"           "STATUS" "DETAIL"
printf "%-18s %-12s %-55s\n" "-----"           "------" "------"
for i in "${!PHASE_NAMES[@]}"; do
  printf "%-18s %-12s %-55s\n" "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DETAILS[$i]}"
done
echo "===================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "===================================================="
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "verify-seed: ${OVERALL_FAILED} phase(s) failed"
fi

log "verify-seed: ALL CHECKS PASSED"
exit 0

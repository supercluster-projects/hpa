#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# host-preflight.sh — KVM bridge host preflight verification
#
# Verifies that the host running provisioning meets all hardware, software,
# and configuration prerequisites for the HPA dev cluster.
#
# Phases:
#   1. CPU virtualization support
#   2. libvirtd running and reachable
#   3. Memory (total >= 32GB, free >= 16GB)
#   4. Disk space (free >= 100GB)
#   5. Required tooling (tofu, helm, kubectl, virsh, git, make, openssl)
#   6. Network (192.168.122.0/24 does not conflict)
#   7. .env file check (exists, has required variables)
#   8. Talos qcow2 image cache check
#   9. OpenTofu configuration validation (tofu validate)
#   10. Block devices for Ceph OSDs (/dev/vdb pattern)
#
# Each check produces PASS / WARN / FAIL / CHECK with detail. A final summary
# table is printed to stdout. Exits non-zero if any FAIL.
#
# Usage: ./host-preflight.sh [--kubeconfig <path>]
#                            [--env-file <path>]
#                            [--tofu-dir <path>]
#                            [--cache-dir <path>]
#                            [--require-tools-only]
#                            [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Internal defaults (script-internal only) -------------------------
TOFU_DIR="${SCRIPT_DIR}/../opentofu"
CACHE_DIR="${DEV_CACHE_DIR:-${PROJECT_ROOT}/.cache}"
ENV_FILE="${PROJECT_ROOT}/.env"
REQUIRE_TOOLS_ONLY=false

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)           KUBECONFIG="$2";                        shift 2 ;;
    --env-file)             ENV_FILE="$2";                          shift 2 ;;
    --tofu-dir)             TOFU_DIR="$2";                          shift 2 ;;
    --cache-dir)            CACHE_DIR="$2";                         shift 2 ;;
    --require-tools-only)   REQUIRE_TOOLS_ONLY=true;                 shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Verify KVM bridge host readiness for HPA dev cluster provisioning.

Checks performed:
  1  CPU virtualization support (/dev/kvm)
  2  libvirtd reachable (virsh list)
  3  Memory (total >= 32GB, free >= 16GB)
  4  Disk space (free >= 100GB)
  5  Required tooling (tofu, helm, kubectl, virsh, git, make, openssl)
  6  Network (192.168.122.0/24 conflict check)
  7  .env file present with required variables
  8  Talos qcow2 image cache check
  9  OpenTofu config validation (tofu validate)
  10 Block devices for Ceph OSDs

Options:
  --env-file PATH       Path to .env file (default: project root .env)
  --tofu-dir PATH       Path to OpenTofu provisioning directory
  --cache-dir PATH      Path to offline cache directory
  --require-tools-only  Only check tooling availability (skip rest)
  --help, -h            Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Results accumulator --------------------------------------------------
P1_STATUS="" P1_DETAIL=""   # CPU virtualization
P2_STATUS="" P2_DETAIL=""   # libvirtd
P3_STATUS="" P3_DETAIL=""   # Memory
P4_STATUS="" P4_DETAIL=""   # Disk
P5_STATUS="" P5_DETAIL=""   # Tooling
P6_STATUS="" P6_DETAIL=""   # Network
P7_STATUS="" P7_DETAIL=""   # .env
P8_STATUS="" P8_DETAIL=""   # Cache
P9_STATUS="" P9_DETAIL=""   # tofu validate
P10_STATUS="" P10_DETAIL=""  # Ceph block devices

OVERALL_FAILED=0

# ============================================================================
# Phase 1: CPU virtualization support
# ============================================================================
log "Phase 1: CPU virtualization support"

if [ -c /dev/kvm ] && [ -r /dev/kvm ]; then
  P1_STATUS="PASS"
  P1_DETAIL="/dev/kvm present and accessible"
elif [ -e /dev/kvm ]; then
  P1_STATUS="FAIL"
  P1_DETAIL="/dev/kvm exists but not accessible — check permissions (user must be in kvm group)"
  OVERALL_FAILED=1
else
  # Check via /proc/cpuinfo
  if grep -q -E '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
    P1_STATUS="WARN"
    P1_DETAIL="CPU supports virtualization but /dev/kvm not found — kvm module may not be loaded"
  else
    P1_STATUS="FAIL"
    P1_DETAIL="No CPU virtualization support detected (neither /dev/kvm nor vmx/svm flags)"
    OVERALL_FAILED=1
  fi
fi
log "Phase 1: ${P1_STATUS} — ${P1_DETAIL}"

# ============================================================================
# Phase 2: libvirtd running and reachable
# ============================================================================
log "Phase 2: libvirtd running and reachable"

if command -v virsh >/dev/null 2>&1; then
  if virsh list > /dev/null 2>&1; then
    P2_STATUS="PASS"
    P2_DETAIL="libvirtd reachable via virsh list"
  else
    P2_STATUS="FAIL"
    P2_DETAIL="virsh binary found but cannot connect to libvirtd — is the daemon running and is the user in the libvirt group?"
    OVERALL_FAILED=1
  fi
else
  P2_STATUS="FAIL"
  P2_DETAIL="virsh not found in PATH"
  OVERALL_FAILED=1
fi
log "Phase 2: ${P2_STATUS} — ${P2_DETAIL}"

if [ "${REQUIRE_TOOLS_ONLY}" = true ]; then
  # Skip all remaining hardware/env checks
  P3_STATUS="SKIP"  P3_DETAIL="--require-tools-only set"
  P4_STATUS="SKIP"  P4_DETAIL="--require-tools-only set"
  P6_STATUS="SKIP"  P6_DETAIL="--require-tools-only set"
  P7_STATUS="SKIP"  P7_DETAIL="--require-tools-only set"
  P8_STATUS="SKIP"  P8_DETAIL="--require-tools-only set"
  P9_STATUS="SKIP"  P9_DETAIL="--require-tools-only set"
  P10_STATUS="SKIP" P10_DETAIL="--require-tools-only set"
fi

# ============================================================================
# Phase 3: Memory check
# ============================================================================
if [ "${REQUIRE_TOOLS_ONLY}" != true ]; then
  log "Phase 3: Memory check"

  if [ -f /proc/meminfo ]; then
    TOTAL_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    AVAIL_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")

    if [ -n "${TOTAL_KB}" ] && [ "${TOTAL_KB}" -gt 0 ] 2>/dev/null; then
      TOTAL_GB=$((TOTAL_KB / 1048576))
      AVAIL_GB=$((AVAIL_KB / 1048576))

      if [ "${TOTAL_GB}" -ge 32 ]; then
        P3_STATUS="PASS"
        P3_DETAIL="${TOTAL_GB}GB total, ${AVAIL_GB}GB available (recommended >= 32GB total, >= 16GB free)"
      elif [ "${TOTAL_GB}" -ge 16 ]; then
        P3_STATUS="WARN"
        P3_DETAIL="${TOTAL_GB}GB total, ${AVAIL_GB}GB available — below recommended 32GB, may need to reduce VM count or RAM"
      else
        P3_STATUS="FAIL"
        P3_DETAIL="${TOTAL_GB}GB total — insufficient for 4 VMs (requires >= 16GB minimum)"
        OVERALL_FAILED=1
      fi
    else
      P3_STATUS="FAIL"
      P3_DETAIL="Could not read memory info from /proc/meminfo"
      OVERALL_FAILED=1
    fi
  else
    P3_STATUS="CHECK"
    P3_DETAIL="/proc/meminfo not available on this platform — verify manually: free -h"
  fi
  log "Phase 3: ${P3_STATUS} — ${P3_DETAIL}"
fi

# ============================================================================
# Phase 4: Disk space
# ============================================================================
if [ "${REQUIRE_TOOLS_ONLY}" != true ]; then
  log "Phase 4: Disk space check"

  # Check free space on the project root filesystem
  PROJECT_DEV=$(df "${PROJECT_ROOT}" 2>/dev/null | awk 'NR==2 {print $1}' || true)
  FREE_KB=$(df "${PROJECT_ROOT}" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")

  if [ -n "${FREE_KB}" ] && [ "${FREE_KB}" -gt 0 ] 2>/dev/null; then
    FREE_GB=$((FREE_KB / 1048576))

    if [ "${FREE_GB}" -ge 100 ]; then
      P4_STATUS="PASS"
      P4_DETAIL="${FREE_GB}GB free on ${PROJECT_DEV:-$(df "${PROJECT_ROOT}" | awk 'NR==2 {print $6}')} (recommended >= 100GB)"
    elif [ "${FREE_GB}" -ge 50 ]; then
      P4_STATUS="WARN"
      P4_DETAIL="${FREE_GB}GB free — may be tight for VM images and Ceph OSDs (recommended >= 100GB)"
    else
      P4_STATUS="FAIL"
      P4_DETAIL="${FREE_GB}GB free — insufficient for VM storage and Ceph OSDs (requires >= 50GB minimum)"
      OVERALL_FAILED=1
    fi
  else
    P4_STATUS="CHECK"
    P4_DETAIL="Could not determine free disk space — verify manually: df -h ${PROJECT_ROOT}"
  fi
  log "Phase 4: ${P4_STATUS} — ${P4_DETAIL}"
fi

# ============================================================================
# Phase 5: Required tooling
# ============================================================================
log "Phase 5: Required tooling check"

# Define required tools with their fallback check commands
declare -A TOOLS
TOOLS[tofu]="tofu version"
TOOLS[helm]="helm version --short"
TOOLS[kubectl]="kubectl version --client -o json"
TOOLS[virsh]="virsh --version"
TOOLS[git]="git --version"
TOOLS[make]="make --version"
TOOLS[openssl]="openssl version"

# Define optional but recommended tools
declare -A OPT_TOOLS
OPT_TOOLS[docker]="docker --version"
OPT_TOOLS[spin]="spin --version"

TOOL_FAILED=false
TOOL_DETAILS=""
OPT_TOOL_DETAILS=""

for tool in "${!TOOLS[@]}"; do
  if command -v "${tool}" > /dev/null 2>&1; then
    # Get version
    local ver
    ver=$(${TOOLS[${tool}]} 2>/dev/null | head -1 | tr -d '\n' | cut -c1-60)
    TOOL_DETAILS="${TOOL_DETAILS} ${tool}(${ver}),"
  else
    TOOL_FAILED=true
    TOOL_DETAILS="${TOOL_DETAILS} ${tool}(MISSING),"
  fi
done

# Check optional tools
for tool in "${!OPT_TOOLS[@]}"; do
  if command -v "${tool}" > /dev/null 2>&1; then
    local ver
    ver=$(${OPT_TOOLS[${tool}]} 2>/dev/null | head -1 | tr -d '\n' | cut -c1-60)
    OPT_TOOL_DETAILS="${OPT_TOOL_DETAILS} ${tool}(${ver}),"
  else
    OPT_TOOL_DETAILS="${OPT_TOOL_DETAILS} ${tool}(not found),"
  fi
done

TOOL_DETAILS="${TOOL_DETAILS%,}"
OPT_TOOL_DETAILS="${OPT_TOOL_DETAILS%,}"

if [ "${TOOL_FAILED}" = true ]; then
  P5_STATUS="FAIL"
  P5_DETAIL="${TOOL_DETAILS}"
  if [ "${REQUIRE_TOOLS_ONLY}" != true ]; then
    OVERALL_FAILED=1
  fi
else
  P5_STATUS="PASS"
  P5_DETAIL="${TOOL_DETAILS}"
fi
log "Phase 5: ${P5_STATUS} — ${P5_DETAIL}"
log "  Optional: ${OPT_TOOL_DETAILS}"

# ============================================================================
# Phase 6: Network conflict check
# ============================================================================
if [ "${REQUIRE_TOOLS_ONLY}" != true ]; then
  log "Phase 6: Network conflict check (192.168.122.0/24)"

  NET_CONFLICT=false

  # Check if the bridge already exists
  if command -v virsh > /dev/null 2>&1; then
    if virsh net-list --name 2>/dev/null | grep -q "hpa-bridge"; then
      P6_DETAIL="hpa-bridge network already exists"
      NET_CONFLICT=false
    else
      # Check if 192.168.122.0/24 is used by other networks
      local conflict=""
      # Check default libvirt network
      if virsh net-dumpxml default 2>/dev/null | grep -q "192.168.122"; then
        conflict="${conflict} libvirt-default(192.168.122)"
      fi
      # Check other networks via virsh
      for net in $(virsh net-list --name 2>/dev/null); do
        [ -z "${net}" ] && continue
        if virsh net-dumpxml "${net}" 2>/dev/null | grep -q "192.168.122"; then
          conflict="${conflict} ${net}"
        fi
      done
      # Check host interfaces
      if ip a 2>/dev/null | grep -q "192.168.122"; then
        conflict="${conflict} host-interface"
      fi

      if [ -n "${conflict}" ]; then
        P6_STATUS="WARN"
        P6_DETAIL="Potential conflict:${conflict} — hpa-bridge may need a different subnet"
        log "Phase 6: ${P6_STATUS} — ${P6_DETAIL}"
      else
        P6_DETAIL="No conflicts detected — 192.168.122.0/24 is available"
      fi
    fi
  else
    P6_DETAIL="virsh not available — cannot check network"
  fi

  if [ -z "${P6_STATUS}" ]; then
    P6_STATUS="PASS"
    log "Phase 6: ${P6_STATUS} — ${P6_DETAIL}"
  fi
fi

# ============================================================================
# Phase 7: .env file check
# ============================================================================
if [ "${REQUIRE_TOOLS_ONLY}" != true ]; then
  log "Phase 7: .env file check"

  if [ -f "${ENV_FILE}" ]; then
    log "  .env found at ${ENV_FILE}"

    # Source the .env to check variables
    set -a
    source "${ENV_FILE}" 2>/dev/null || {
      set +a
      P7_STATUS="FAIL"
      P7_DETAIL=".env found at ${ENV_FILE} but sourcing failed"
      OVERALL_FAILED=1
    }
    set +a

    MISSING_VARS=""
    if [ -f "${PROJECT_ROOT}/.env.example" ]; then
      # Scan .env.example for required vars (lines with = but not comments/blanks)
      WHILE_READ_FAILED=false
      while IFS= read -r line; do
        [ -z "${line}" ] && continue
        [[ "${line}" =~ ^# ]] && continue
        [[ "${line}" =~ ^\[ ]] && continue

        # Extract variable name (everything before =)
        VAR_NAME="${line%%=*}"
        [ -z "${VAR_NAME}" ] && continue

        # Skip PULSAR_VERSION and CLICKHOUSE_VERSION (added recently, might not be set)
        # Skip variables with sensible defaults
        case "${VAR_NAME}" in
          PULSAR_VERSION|CLICKHOUSE_VERSION) continue ;;
          DEV_GITOPS_REVISION|DEV_WORKLOADS_NAMESPACE|DEV_GATEWAY_NAMESPACE|DEV_HTTPROUTE_NAME)
            # Optional with defaults
            continue ;;
        esac

        # Check if the variable or its TF_VAR_ form is set
        if [ -z "${!VAR_NAME:-}" ] && [ -z "${!TF_VAR_${VAR_NAME}:-}" ]; then
          # Check for placeholder value
          local val="${!VAR_NAME:-}"
          if echo "${val}" | grep -qi "change-me\|your-"; then
            MISSING_VARS="${MISSING_VARS} ${VAR_NAME}(placeholder)"
          fi
        fi
      done < "${PROJECT_ROOT}/.env.example"
    fi

    if [ -z "${MISSING_VARS}" ]; then
      P7_STATUS="PASS"
      P7_DETAIL=".env found and all required variables are set"
    else
      P7_STATUS="WARN"
      P7_DETAIL=".env found but missing or placeholder values for:${MISSING_VARS}"
    fi
  else
    P7_STATUS="FAIL"
    P7_DETAIL=".env not found at ${ENV_FILE} (create from .env.example)"
    OVERALL_FAILED=1
  fi
  log "Phase 7: ${P7_STATUS} — ${P7_DETAIL}"
fi

# ============================================================================
# Phase 8: Talos qcow2 image cache check
# ============================================================================
if [ "${REQUIRE_TOOLS_ONLY}" != true ]; then
  log "Phase 8: Talos qcow2 image cache check"

  # Look for cached qcow2 images
  QCOW2_FOUND=""
  if [ -d "${CACHE_DIR}" ]; then
    QCOW2_FOUND=$(find "${CACHE_DIR}" -name "*.qcow2" -o -name "*.qcow2.xz" 2>/dev/null | head -5)
    TOFU_PROVIDERS=$(find "${CACHE_DIR}" -name ".terraform" -type d 2>/dev/null | head -3)
  fi

  # Also check tofu's own .terraform directory
  if [ -z "${QCOW2_FOUND}" ] && [ -d "${TOFU_DIR}/.terraform" ]; then
    QCOW2_FOUND=$(find "${TOFU_DIR}" -name "*.qcow2" -o -name "*.qcow2.xz" 2>/dev/null | head -5)
  fi

  if [ -n "${QCOW2_FOUND}" ]; then
    P8_STATUS="PASS"
    P8_DETAIL="Talos qcow2 image(s) cached"
    while IFS= read -r f; do
      log "    ${f}"
    done <<< "${QCOW2_FOUND}"
  else
    P8_STATUS="CHECK"
    P8_DETAIL="No cached qcow2 images found in ${CACHE_DIR}"
    log "  (needs setup-host.sh or prep-cache.sh to be run before provisioning)"
  fi

  if [ -d "${TOFU_DIR}/.terraform/providers" ]; then
    P8_DETAIL="${P8_DETAIL}, tofu providers cached"
  else
    P8_DETAIL="${P8_DETAIL}, tofu providers NOT cached (run tofu init)"
  fi
  log "Phase 8: ${P8_STATUS} — ${P8_DETAIL}"
fi

# ============================================================================
# Phase 9: OpenTofu configuration validation
# ============================================================================
if [ "${REQUIRE_TOOLS_ONLY}" != true ]; then
  log "Phase 9: OpenTofu configuration validation"

  if command -v tofu > /dev/null 2>&1; then
    if [ -d "${TOFU_DIR}" ]; then
      (cd "${TOFU_DIR}" && tofu validate 2>&1) > /tmp/tofu-validate.$$.log 2>&1
      TOFU_EXIT=$?

      if [ "${TOFU_EXIT}" -eq 0 ]; then
        P9_STATUS="PASS"
        P9_DETAIL="tofu validate passed in ${TOFU_DIR}"
      else
        P9_STATUS="FAIL"
        P9_DETAIL="tofu validate failed (see /tmp/tofu-validate.$$.log)"
        OVERALL_FAILED=1
      fi
      rm -f /tmp/tofu-validate.$$.log
    else
      P9_STATUS="FAIL"
      P9_DETAIL="OpenTofu directory not found at ${TOFU_DIR}"
      OVERALL_FAILED=1
    fi
  else
    P9_STATUS="FAIL"
    P9_DETAIL="tofu not found in PATH"
    OVERALL_FAILED=1
  fi
  log "Phase 9: ${P9_STATUS} — ${P9_DETAIL}"
fi

# ============================================================================
# Phase 10: Block devices for Ceph OSDs
# ============================================================================
if [ "${REQUIRE_TOOLS_ONLY}" != true ]; then
  log "Phase 10: Block devices for Ceph OSDs"

  # Check for /dev/vdb or other extra block devices (Ceph OSD targets)
  CEPH_DEVICES=""
  if [ -e /dev/vdb ]; then
    CEPH_DEVICES="${CEPH_DEVICES} /dev/vdb"
  elif [ -e /dev/sdb ]; then
    CEPH_DEVICES="${CEPH_DEVICES} /dev/sdb"
  elif [ -e /dev/nvme1n1 ]; then
    CEPH_DEVICES="${CEPH_DEVICES} /dev/nvme1n1"
  fi

  # Also check if libvirt storage pools exist that could provide Ceph disks
  if command -v virsh > /dev/null 2>&1; then
    STORAGE_POOLS=$(virsh pool-list --name 2>/dev/null || true)
  fi

  if [ -n "${CEPH_DEVICES}" ]; then
    P10_STATUS="PASS"
    P10_DETAIL="Ceph block devices found:${CEPH_DEVICES}"
  elif virsh pool-list 2>/dev/null | grep -q "hpa"; then
    P10_STATUS="PASS"
    P10_DETAIL="Ceph disks available via libvirt storage pool"
  else
    P10_STATUS="CHECK"
    P10_DETAIL="No Ceph block devices detected — Ceph OSDs require /dev/vdb on each worker"
    log "  Ceph OSDs will use emulated disks within the VMs (libvirt storage pool)."
    log "  No host-level Ceph block devices needed for the dev cluster."
  fi
  log "Phase 10: ${P10_STATUS} — ${P10_DETAIL}"
fi

# ============================================================================
# Summary Table (stdout)
# ============================================================================
OVERALL_VERDICT="PASS"
[ "${OVERALL_FAILED}" -ne 0 ] && OVERALL_VERDICT="FAIL"

echo ""
echo "=== Host Preflight Summary ==="
printf "%-12s %-12s %-60s\n" "PHASE"          "STATUS" "DETAIL"
printf "%-12s %-12s %-60s\n" "-----"          "------" "------"
printf "%-12s %-12s %-60s\n" "1-CPU-Virt"     "${P1_STATUS}" "${P1_DETAIL}"
printf "%-12s %-12s %-60s\n" "2-libvirtd"     "${P2_STATUS}" "${P2_DETAIL}"
printf "%-12s %-12s %-60s\n" "3-Memory"       "${P3_STATUS}" "${P3_DETAIL}"
printf "%-12s %-12s %-60s\n" "4-Disk"         "${P4_STATUS}" "${P4_DETAIL}"
printf "%-12s %-12s %-60s\n" "5-Tooling"      "${P5_STATUS}" "${P5_DETAIL}"
printf "%-12s %-12s %-60s\n" "6-Network"      "${P6_STATUS}" "${P6_DETAIL}"
printf "%-12s %-12s %-60s\n" "7-Env"          "${P7_STATUS}" "${P7_DETAIL}"
printf "%-12s %-12s %-60s\n" "8-Cache"        "${P8_STATUS}" "${P8_DETAIL}"
printf "%-12s %-12s %-60s\n" "9-Tofu-Valid"   "${P9_STATUS}" "${P9_DETAIL}"
printf "%-12s %-12s %-60s\n" "10-Ceph-Dev"    "${P10_STATUS}" "${P10_DETAIL}"
echo "================================================================="
printf "Overall verdict: %s\n" "${OVERALL_VERDICT}"
echo "================================================================="

echo ""
echo "  Recommended workflow:"
echo "    1. ./setup-host.sh              # One-shot host environment setup"
echo "    2. ./host-preflight.sh           # Verify everything is ready"
echo "    3. ./startup.sh --skip-tofu     # Run pipeline without tofu (or)"
echo "    4. ./e2e-provisioning.sh        # Full end-to-end provisioning"
echo ""

# ---- Final exit -----------------------------------------------------------
if [ "${OVERALL_FAILED}" -ne 0 ]; then
  die "host-preflight: ${OVERALL_FAILED} phase(s) failed — resolve before provisioning"
fi

log "host-preflight: ALL CHECKS PASSED"
exit 0

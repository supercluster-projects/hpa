#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cluster-create.sh — Create a throwaway Talos K8s dev cluster (QEMU)
#
# Wraps talosctl cluster create qemu with sensible defaults from .env and CLI
# overrides. Creates a multi-node Talos cluster using local QEMU VMs.
# No libvirt, no OpenTofu, no hpa-bridge required — just talosctl.
#
# Usage: ./cluster-create.sh [options]
#
# Options:
#   --name NAME                Cluster name (default: $DEV_CLUSTER_NAME)
#   --controlplanes N          Number of control plane nodes (default: $DEV_CP_COUNT)
#   --workers N                Number of worker nodes (default: $DEV_WORKER_COUNT)
#   --cpus-controlplanes CPUS  vCPUs fraction per control plane (default: $DEV_VM_CPU)
#   --cpus-workers CPUS        vCPUs fraction per worker (default: $DEV_VM_CPU)
#   --memory-controlplanes MEM CP RAM (e.g. 4096MiB or 4GiB, default: ${DEV_CP_RAM_MB}MiB)
#   --memory-workers MEM       Worker RAM (e.g. 3072MiB or 3GiB, default: ${DEV_WORKER_RAM_MB}MiB)
#   --talos-version VERSION    Talos version (default: $TALOS_VERSION)
#   --kubernetes-version VER   Kubernetes version (optional, overrides talosctl default)
#   --disk-gb GB               OS disk size in GB for first virtio disk (default: $DEV_OS_DISK_SIZE_GB)
#   --ceph-disk-gb GB          Ceph extra disk size in GB for second virtio disk (default: $DEV_CEPH_DISK_SIZE_GB)
#   --presets PRESETS          Comma-separated presets (default: iso)
#   --config-patch PATCH       Additional config patch (can be repeated, accumulates)
#   --state DIR                Talos state directory
#   --cidr CIDR                Cluster network CIDR (default: 10.5.0.0/24)
#   --image-factory-url URL    Image Factory URL (optional)
#   --image-factory-auth AUTH  Image Factory auth user:pass (optional)
#   --schematic-id ID          Image Factory schematic ID for custom images (optional)
#   --no-wait                  Alias: not used directly. Use --presets=iso for non-waiting boot.
#   --help, -h                 Show this help message
#
# Environment:
#   .env file at project root sourced automatically if present
#   CLI flags override env vars which override script defaults
#
# Requires: talosctl, kubectl
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults (from .env or built-in) ------------------------------------
CLUSTER_NAME="${DEV_CLUSTER_NAME:-hpa-dev}"
CP_COUNT="${DEV_CP_COUNT:-1}"
WORKER_COUNT="${DEV_WORKER_COUNT:-3}"
TALOS_VER="${TALOS_VERSION:-v1.13.5}"
K8S_VERSION=""
CPU_CP="${DEV_VM_CPU:-2}"
CPU_WORKER="${DEV_VM_CPU:-2}"
MEM_CP="${DEV_CP_RAM_MB:-4096}MiB"
MEM_WORKER="${DEV_WORKER_RAM_MB:-3072}MiB"
DISK_GB="${DEV_OS_DISK_SIZE_GB:-20}"
CEPH_DISK_GB="${DEV_CEPH_DISK_SIZE_GB:-20}"
declare -a CONFIG_PATCHES=()
STATE_DIR=""
CLUSTER_CIDR=""
IMAGE_FACTORY_URL=""
IMAGE_FACTORY_AUTH=""
SCHEMATIC_ID=""
PRESETS="iso"

# Resolve the config-patch file path (relative to script dir)
CONFIG_PATCH_FILE="$(cd "${SCRIPT_DIR}/../opentofu" && pwd)/cluster-config.yaml"

# ---- CLI flag parsing ----------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)                  CLUSTER_NAME="$2";          shift 2 ;;
    --controlplanes)         CP_COUNT="$2";              shift 2 ;;
    --workers)               WORKER_COUNT="$2";          shift 2 ;;
    --cpus-controlplanes)    CPU_CP="$2";                shift 2 ;;
    --cpus-workers)          CPU_WORKER="$2";            shift 2 ;;
    --memory-controlplanes)  MEM_CP="$2";                shift 2 ;;
    --memory-workers)        MEM_WORKER="$2";            shift 2 ;;
    --talos-version)         TALOS_VER="$2";             shift 2 ;;
    --kubernetes-version)    K8S_VERSION="$2";           shift 2 ;;
    --disk-gb)               DISK_GB="$2";               shift 2 ;;
    --ceph-disk-gb)          CEPH_DISK_GB="$2";          shift 2 ;;
    --config-patch)          CONFIG_PATCHES+=("$2");     shift 2 ;;
    --state)                 STATE_DIR="$2";             shift 2 ;;
    --cidr)                  CLUSTER_CIDR="$2";          shift 2 ;;
    --image-factory-url)     IMAGE_FACTORY_URL="$2";     shift 2 ;;
    --image-factory-auth)    IMAGE_FACTORY_AUTH="$2";    shift 2 ;;
    --schematic-id)          SCHEMATIC_ID="$2";          shift 2 ;;
    --presets)               PRESETS="$2";               shift 2 ;;
    --no-wait)               : ;; # accepted for compatibility, no-op (talosctl already non-blocking by default for qemu)
    --help|-h)
      cat <<HELP
Usage: $(basename "$0") [options]

Create a throwaway Talos K8s dev cluster using talosctl cluster create qemu.
No libvirt, no OpenTofu, no hpa-bridge required — just talosctl and QEMU.

Options:
  --name NAME                Cluster name (default: ${DEV_CLUSTER_NAME:-hpa-dev})
  --controlplanes N          Control plane count (default: ${DEV_CP_COUNT:-1})
  --workers N                Worker count (default: ${DEV_WORKER_COUNT:-3})
  --cpus-controlplanes CPUS  vCPUs/CP (default: ${DEV_VM_CPU:-2})
  --cpus-workers CPUS        vCPUs/worker (default: ${DEV_VM_CPU:-2})
  --memory-controlplanes MEM  CP RAM (default: ${DEV_CP_RAM_MB:-4096}MiB)
  --memory-workers MEM        Worker RAM (default: ${DEV_WORKER_RAM_MB:-3072}MiB)
  --talos-version VERSION    Talos version (default: ${TALOS_VERSION:-v1.13.5})
  --kubernetes-version VER   K8s version (optional, talosctl default: 1.36.0)
  --disk-gb GB               OS disk (default: ${DEV_OS_DISK_SIZE_GB:-20})
  --ceph-disk-gb GB          Extra disk for Ceph (default: ${DEV_CEPH_DISK_SIZE_GB:-20})
  --presets PRESETS          Presets (default: iso)
  --config-patch PATCH       Config patch (repeatable, accumulated)
  --state DIR                Talos state dir
  --cidr CIDR                Cluster CIDR (default: 10.5.0.0/24)
  --image-factory-url URL    Image Factory URL (optional)
  --image-factory-auth AUTH  Image Factory auth (optional)
  --schematic-id ID          Image Factory schematic ID (optional)
  --help, -h                 Show this help

Environment:
  .env file at project root sourced automatically if present.
  CLI flags override env vars which override script defaults.

Examples:
  ./cluster-create.sh                                    # defaults from .env
  ./cluster-create.sh --workers 5 --cpus-workers 4       # overrides
  ./cluster-create.sh --name my-test                     # quick test cluster
  ./cluster-create.sh --disk-gb 30 --ceph-disk-gb 40     # bigger disks
  ./cluster-create.sh --config-patch @./extra-patch.yaml  # custom patch

Requires: talosctl, kubectl
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Pre-flight checks ---------------------------------------------------
command -v talosctl >/dev/null 2>&1 || die "talosctl not found in PATH"

log "=========================================================="
log "Creating Talos QEMU cluster: ${CLUSTER_NAME}"
log "=========================================================="
log "  controlplanes:      ${CP_COUNT}"
log "  workers:            ${WORKER_COUNT}"
log "  cpus (cp):          ${CPU_CP}"
log "  cpus (worker):      ${CPU_WORKER}"
log "  memory (cp):        ${MEM_CP}"
log "  memory (worker):    ${MEM_WORKER}"
log "  talos version:      ${TALOS_VER}"
if [ -n "${K8S_VERSION}" ]; then
  log "  k8s version:        ${K8S_VERSION}"
fi
log "  os disk:            ${DISK_GB} GiB"
log "  ceph extra disk:    ${CEPH_DISK_GB} GiB (per worker)"
log "  presets:            ${PRESETS}"
log ""

# ---- Build config-patch arguments -----------------------------------------
# 1. Reference the full cluster-config.yaml via @file
if [ -f "${CONFIG_PATCH_FILE}" ]; then
  log "Using config patch: ${CONFIG_PATCH_FILE}"
  CONFIG_PATCHES+=("@${CONFIG_PATCH_FILE}")
else
  log "  Warning: cluster-config.yaml not found at ${CONFIG_PATCH_FILE}"
  log "  (continuing without it — some features may be missing)"
fi

# 2. Generate an inline config-patch for net.ifnames=0 kernel arg
#    (Disables predictable network interface naming so interfaces appear as
#    eth0/eth1 rather than enpXsY; required for consistent bond device naming.)
NET_IFNAMES_PATCH=$(mktemp)
trap 'rm -f "${NET_IFNAMES_PATCH}"' EXIT
cat > "${NET_IFNAMES_PATCH}" << 'PATCH_EOF'
machine:
  install:
    extraKernelArgs:
      - net.ifnames=0
PATCH_EOF
CONFIG_PATCHES+=("@${NET_IFNAMES_PATCH}")

log "Config patches: ${#CONFIG_PATCHES[@]} total"
for patch in "${CONFIG_PATCHES[@]}"; do
  if [[ "${patch}" == @* ]]; then
    log "  ${patch}"
  else
    log "  (inline patch)"
  fi
done
log ""

# ---- Build talosctl command -----------------------------------------------
# Disks: first virtio disk for OS, second virtio disk for Ceph (workers only)
DISKS_SPEC="virtio:${DISK_GB}GiB,virtio:${CEPH_DISK_GB}GiB"

TALOSCTL_CMD=(talosctl cluster create qemu
  --name "${CLUSTER_NAME}"
  --controlplanes "${CP_COUNT}"
  --workers "${WORKER_COUNT}"
  --cpus-controlplanes "${CPU_CP}"
  --cpus-workers "${CPU_WORKER}"
  --memory-controlplanes "${MEM_CP}"
  --memory-workers "${MEM_WORKER}"
  --talos-version "${TALOS_VER}"
  --disks "${DISKS_SPEC}"
  --presets "${PRESETS}"
)

if [ -n "${K8S_VERSION}" ]; then
  TALOSCTL_CMD+=(--kubernetes-version "${K8S_VERSION}")
fi

if [ -n "${STATE_DIR}" ]; then
  TALOSCTL_CMD+=(--state "${STATE_DIR}")
fi

if [ -n "${CLUSTER_CIDR}" ]; then
  TALOSCTL_CMD+=(--cidr "${CLUSTER_CIDR}")
fi

if [ -n "${IMAGE_FACTORY_URL}" ]; then
  TALOSCTL_CMD+=(--image-factory-url "${IMAGE_FACTORY_URL}")
fi

if [ -n "${IMAGE_FACTORY_AUTH}" ]; then
  TALOSCTL_CMD+=(--image-factory-auth "${IMAGE_FACTORY_AUTH}")
fi

if [ -n "${SCHEMATIC_ID}" ]; then
  TALOSCTL_CMD+=(--schematic-id "${SCHEMATIC_ID}")
fi

# Append accumulated config patches
for patch in "${CONFIG_PATCHES[@]}"; do
  TALOSCTL_CMD+=(--config-patch "${patch}")
done

# ---- Run talosctl ----------------------------------------------------------
log "Running talosctl cluster create qemu..."
log "  Command: ${TALOSCTL_CMD[*]}"
log ""
log "  This typically takes 1-3 minutes..."
log ""

# Trap on interrupt for user feedback
interrupted() {
  log ""
  log "Interrupt received. The cluster may be partially created."
  log "  To clean up, run: cluster-destroy.sh"
  exit 1
}
trap interrupted SIGINT SIGTERM

if "${TALOSCTL_CMD[@]}"; then
  log "talosctl cluster create completed successfully."
else
  die "talosctl cluster create failed (exit code $?)"
fi

# ---- Post-creation summary ------------------------------------------------
DURATION=$(( $(date +%s) - START_TIME ))
MINUTES=$(( DURATION / 60 ))
SECONDS=$(( DURATION % 60 ))

# Determine kubeconfig location (talosctl writes kubeconfig to the state dir)
STATE_DIR_FINAL="${STATE_DIR:-${HOME}/.talos/clusters/${CLUSTER_NAME}}"
FINAL_KUBECONFIG="${STATE_DIR_FINAL}/kubeconfig"

log ""
log "=========================================================="
log "Cluster Created!"
log "=========================================================="
log "  Cluster:    ${CLUSTER_NAME}"
log "  Nodes:      $(( CP_COUNT + WORKER_COUNT )) ($(( CP_COUNT )) cp + $(( WORKER_COUNT )) worker)"
log "  Duration:   ${MINUTES}m ${SECONDS}s"
log "  State:      ${STATE_DIR_FINAL}"
log "  kubeconfig: ${FINAL_KUBECONFIG}"
log ""

# Show current kubectl context if kubeconfig is accessible
if [ -f "${FINAL_KUBECONFIG}" ]; then
  CONTEXT_NAME=$(KUBECONFIG="${FINAL_KUBECONFIG}" kubectl config current-context 2>/dev/null || echo "${CLUSTER_NAME}")
  log "  Context:    ${CONTEXT_NAME}"
fi

log ""
log "  To interact with the cluster:"
log "    export KUBECONFIG=${FINAL_KUBECONFIG}"
log "    kubectl get nodes"
log "    kubectl cluster-info"
log ""
log "  To destroy the cluster when done:"
log "    ./cluster-destroy.sh"
log "=========================================================="

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# prebuild-talos-images.sh — Pre-build Talos VM images for fast boot
#
# Creates pre-expanded 20GB QCOW2 images for each node to eliminate
# the Copy-On-Write (COW) disk expansion delay during first boot.
#
# Usage: prebuild-talos-images.sh [--overwrite] [--output-dir DIR]
#
# Options:
#   --overwrite    Recreate images even if they already exist
#   --output-dir   Directory to store pre-built images (default: ./prebuilt-images/)
#
# Output: 20GB flat images that can be used as direct sources in main.tf
#
# Note: This script creates images in the project directory or /tmp.
# To use with libvirt, you may need to:
#   1. Copy images to /var/lib/libvirt/images/ (requires sudo)
#   2. Or update main.tf to use the images from this location
# ---------------------------------------------------------------------------
set -euo pipefail

# Source preamble for logging and error handling
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# Configuration
BASE_IMAGE="${PROJECT_ROOT}/.cache/talos-v1.13.5-metal-amd64.qcow2"
DEFAULT_OUTPUT_DIR="${PROJECT_ROOT}/prebuilt-images"
DISK_SIZE_GB=20
OVERWRITE=false
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --overwrite)
      OVERWRITE=true
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# Node names from terraform locals
NODES=("hpa-node-cp-0" "hpa-node-worker-0" "hpa-node-worker-1" "hpa-node-worker-2")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

STEP_START "Pre-build Talos VM images"

# Verify base image exists
if [ ! -f "${BASE_IMAGE}" ]; then
  die "Base Talos image not found at ${BASE_IMAGE}"
fi

# Check if qemu-img is available
command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found in PATH"

# Create output directory
mkdir -p "${OUTPUT_DIR}" || die "Failed to create ${OUTPUT_DIR}"
log "Output directory: ${OUTPUT_DIR}"

# Create/update images
for node in "${NODES[@]}"; do
  IMAGE_PATH="${OUTPUT_DIR}/${node}-os.qcow2"
  
  if [ -f "${IMAGE_PATH}" ] && [ "${OVERWRITE}" = false ]; then
    SIZE=$(du -h "${IMAGE_PATH}" 2>/dev/null | cut -f1 || echo "unknown")
    log "Image exists: ${IMAGE_PATH} (${SIZE}) - skipping, use --overwrite to recreate"
    continue
  fi
  
  log "Creating pre-expanded image for ${node}..."
  
  # Create 20GB pre-expanded image with metadata preallocation
  # This eliminates the COW expansion delay during first boot
  if qemu-img convert -f qcow2 -O qcow2 \
    -o size=${DISK_SIZE_GB}G,preallocation=metadata \
    "${BASE_IMAGE}" \
    "${IMAGE_PATH}" 2>&1; then
    SIZE=$(du -h "${IMAGE_PATH}" | cut -f1)
    log "Created: ${IMAGE_PATH} (${SIZE})"
  else
    log "WARNING: Failed to create ${IMAGE_PATH}"
  fi
done

# Report final status
echo ""
log "Pre-built images:"
for node in "${NODES[@]}"; do
  IMAGE_PATH="${OUTPUT_DIR}/${node}-os.qcow2"
  if [ -f "${IMAGE_PATH}" ]; then
    SIZE=$(du -h "${IMAGE_PATH}" | cut -f1)
    log "  ${node}-os.qcow2: ${SIZE}"
  fi
done

echo ""
# Copy images to libvirt pool for faster access
LIBVIRT_POOL="/home/cores/.local/share/libvirt/images"
if [ -d "${LIBVIRT_POOL}" ]; then
  log "Copying images to libvirt pool (${LIBVIRT_POOL})..."
  sudo cp "${OUTPUT_DIR}"/*.qcow2 "${LIBVIRT_POOL}/" 2>/dev/null || cp "${OUTPUT_DIR}"/*.qcow2 "${LIBVIRT_POOL}/"
  log "Images copied to libvirt pool"
fi

echo ""
log "To use these pre-built images:"
log "  1. Images auto-copied to libvirt pool: ${LIBVIRT_POOL}"
log "  2. Or update main.tf backing_store path to point to ${OUTPUT_DIR}"
log "  3. Images are 20GB, full filesystem, no first-boot expansion needed"

STEP_END "Pre-build Talos VM images"

log "Pre-built images ready in ${OUTPUT_DIR}"
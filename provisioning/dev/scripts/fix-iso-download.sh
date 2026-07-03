#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fix-iso-download.sh — Download Talos ISO directly to libvirt pool
#
# The libvirt provider's create.content.url mechanism times out on the
# ~200MB ISO download. This script downloads the ISO directly via curl
# and imports it into the libvirt default pool so tofu apply can succeed.
#
# Usage: ./fix-iso-download.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ISO_URL="${1:-https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.13.5/metal-amd64.iso}"
ISO_PATH="/var/lib/libvirt/images/talos-install.iso"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Downloading Talos ISO..."
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   URL: ${ISO_URL}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   DEST: ${ISO_PATH}"

# Download directly to the libvirt pool directory
sudo curl -L -o "${ISO_PATH}" "${ISO_URL}" 2>&1 | tail -5

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Download complete."
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Size: $(sudo wc -c < "${ISO_PATH}") bytes"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   SHA256: $(sudo sha256sum "${ISO_PATH}" | cut -d' ' -f1)"

# Refresh the libvirt pool to recognize the new volume
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Refreshing libvirt default pool..."
sudo virsh pool-refresh default 2>&1

# Verify the volume appears
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Verifying volume in pool..."
sudo virsh vol-list --pool default 2>&1 | grep talos || {
    # If volume doesn't appear, create it from the file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating volume definition..."
    sudo virsh vol-create-from default --file <(cat <<XML
<volume>
  <name>talos-install.iso</name>
  <allocation>0</allocation>
  <capacity unit="bytes">$(sudo stat -c%s "${ISO_PATH}")</capacity>
  <target>
    <path>${ISO_PATH}</path>
    <format type='raw'/>
  </target>
</volume>
XML
    ) 2>&1
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ISO ready. Run tofu apply now."

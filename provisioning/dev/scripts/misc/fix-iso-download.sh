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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

sudo_password() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    return 0
  fi
  if [ "${SUDO_PASSWORD_PROMPTED:-0}" = "1" ]; then
    echo "ERROR: SUDO_PASSWORD is not set and sudo password prompt was already shown" >&2
    exit 1
  fi
  printf '\n' >&2
  read -r -s -p "Enter sudo password: " SUDO_PASSWORD
  printf '\n' >&2
  SUDO_PASSWORD_PROMPTED=1
  [ -n "${SUDO_PASSWORD:-}" ] || { echo "ERROR: SUDO_PASSWORD is required for sudo operations. Set it in .env or enter it when prompted." >&2; exit 1; }
}

run_as_root() {
  command -v sudo >/dev/null 2>&1 || { echo "ERROR: sudo command not found" >&2; exit 1; }
  if command sudo -n true &>/dev/null; then
    command sudo "$@"
    return $?
  fi
  sudo_password || exit 1
  if ! printf '%s\n' "${SUDO_PASSWORD}" | command sudo -S "$@"; then
    echo "ERROR: sudo command failed; check SUDO_PASSWORD or enter a valid password" >&2
    exit 1
  fi
}

sudo() { run_as_root "$@"; }

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

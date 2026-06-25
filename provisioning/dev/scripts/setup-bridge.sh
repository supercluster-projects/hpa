#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-bridge.sh — Create the hpa-bridge libvirt network if it doesn't exist
#
# Checks if the bridge network already exists via 'virsh net-info'. If it
# does, exits 0 immediately (idempotent). Otherwise, defines and starts the
# network using the provided CIDR, gateway, and DHCP range.
#
# All paths are relative to the provisioning/dev/scripts/ directory.
# Usage: ./setup-bridge.sh [--cidr <cidr>] [--gateway <ip>]
#                          [--bridge hpa-bridge] [--dhcp-start .10] [--dhcp-end .200]
# ---------------------------------------------------------------------------
set -euo pipefail

# Source .env directly (no preamble since this runs before cluster exists).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$(cd "${SCRIPT_DIR}/../../.." && pwd)/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

# ---- Required environment variables ---------------------------------------
: "${DEV_BRIDGE_NAME:?Required env var DEV_BRIDGE_NAME not set (see .env.example)}"
: "${DEV_CIDR_BLOCK:?Required env var DEV_CIDR_BLOCK not set (see .env.example)}"

# ---- Internal defaults ----------------------------------------------------
BRIDGE="${DEV_BRIDGE_NAME}"
CIDR="${DEV_CIDR_BLOCK}"
GATEWAY="${CIDR%.*}.1"
DHCP_START="${DHCP_START:-${CIDR%.*}.10}"
DHCP_END="${DHCP_END:-${CIDR%.*}.200}"

# ---- Parse CLI overrides --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge)       BRIDGE="$2";       shift 2 ;;
    --cidr)         CIDR="$2";         shift 2 ;;
    --gateway)      GATEWAY="$2";      shift 2 ;;
    --dhcp-start)   DHCP_START="$2";   shift 2 ;;
    --dhcp-end)     DHCP_END="$2";     shift 2 ;;
    *)              echo "[$(date +%H:%M:%S)] ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---- Validate CIDR --------------------------------------------------------
# Extract netmask from CIDR prefix length
CIDR_PREFIX="${CIDR#*/}"
case "$CIDR_PREFIX" in
  8)  NETMASK="255.0.0.0"     ;;
  16) NETMASK="255.255.0.0"   ;;
  24) NETMASK="255.255.255.0" ;;
  25) NETMASK="255.255.255.128" ;;
  26) NETMASK="255.255.255.192" ;;
  27) NETMASK="255.255.255.224" ;;
  28) NETMASK="255.255.255.240" ;;
  29) NETMASK="255.255.255.248" ;;
  30) NETMASK="255.255.255.252" ;;
  *)  echo "[$(date +%H:%M:%S)] ERROR: Unsupported CIDR prefix length /${CIDR_PREFIX}. Use /8, /16, /24, or /25-/30." >&2; exit 1 ;;
esac

# Derive network address from CIDR (strip the /prefix)
NETWORK_ADDR="${CIDR%/*}"

# ---- Step 1: Check if bridge already exists -------------------------------
echo "[$(date +%H:%M:%S)] Checking if network '${BRIDGE}' exists..." >&2
if virsh net-info "${BRIDGE}" > /dev/null 2>&1; then
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' already exists. Nothing to do. Exiting." >&2
  exit 0
fi
echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' not found. Will create." >&2

# ---- Step 2: Prepare network XML ------------------------------------------
# Build DHCP range: if DHCP_START starts with '.', prepend the network prefix
DHCP_FULL_START="${DHCP_START}"
DHCP_FULL_END="${DHCP_END}"
if [[ "${DHCP_START}" == .* ]]; then
  NET_PREFIX="${NETWORK_ADDR%.*}"
  DHCP_FULL_START="${NET_PREFIX}${DHCP_START}"
fi
if [[ "${DHCP_END}" == .* ]]; then
  NET_PREFIX="${NETWORK_ADDR%.*}"
  DHCP_FULL_END="${NET_PREFIX}${DHCP_END}"
fi

NET_XML=$(mktemp /tmp/hpa-bridge-net-XXXXXX.xml)
trap 'rm -f "${NET_XML}"' EXIT

cat > "${NET_XML}" <<EOF
<network>
  <name>${BRIDGE}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='${GATEWAY}' netmask='${NETMASK}'>
    <dhcp>
      <range start='${DHCP_FULL_START}' end='${DHCP_FULL_END}'/>
    </dhcp>
  </ip>
</network>
EOF

# ---- Step 3: Define and start the network ---------------------------------
echo "[$(date +%H:%M:%S)] Defining network '${BRIDGE}' from XML..." >&2
virsh net-define "${NET_XML}" > /dev/null
echo "[$(date +%H:%M:%S)] Network defined successfully." >&2

echo "[$(date +%H:%M:%S)] Starting network '${BRIDGE}'..." >&2
virsh net-start "${BRIDGE}" > /dev/null
echo "[$(date +%H:%M:%S)] Network started successfully." >&2

# ---- Step 4: Verify -------------------------------------------------------
virsh net-info "${BRIDGE}" > /dev/null 2>&1
echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' is active and ready." >&2
exit 0

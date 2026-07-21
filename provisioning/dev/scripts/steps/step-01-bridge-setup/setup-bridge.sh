#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-bridge.sh — Create libvirt bridge network for the HPA cluster
# Supports both system libvirt (with ROOT_PASSWORD) and L2 mode
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../misc/preamble.sh"

: "${DEV_BRIDGE_NAME:?Required env var DEV_BRIDGE_NAME not set}"
: "${DEV_CIDR_BLOCK:?Required env var DEV_CIDR_BLOCK not set}"

BRIDGE="${DEV_BRIDGE_NAME}"

# ---- Parse CLI overrides ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge)       BRIDGE="$2"; shift 2 ;;
    *)              echo "[$(date +%Y-%m-%d %H:%M:%S)] ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---- Check/create network ----
echo "[$(date +%H:%M:%S)] Checking network '${BRIDGE}'..." >&2

if virsh -c qemu:///system net-info "${BRIDGE}" &>/dev/null; then
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' already exists and is active." >&2
else
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' not found. Creating..." >&2

  NET_XML=$(mktemp /tmp/hpa-bridge-net-XXXXXX.xml)
  trap 'rm -f "${NET_XML}"' EXIT

  # Simple bridge network - no IP/DHCP for bridge mode
  # The cluster VMs will use the host's network for IP assignment
  cat > "${NET_XML}" <<EOF
<network>
  <name>${BRIDGE}</name>
  <forward mode='bridge'/>
  <bridge name='${BRIDGE}'/>
</network>
EOF

  echo "[$(date +%H:%M:%S)] Defining network '${BRIDGE}' from XML..." >&2
  if ! virsh -c qemu:///system net-define "${NET_XML}" 2>&1; then
    die "Failed to define network '${BRIDGE}'"
  fi

  echo "[$(date +%H:%M:%S)] Starting network '${BRIDGE}'..." >&2
  if ! virsh -c qemu:///system net-start "${BRIDGE}" 2>&1; then
    die "Failed to start network '${BRIDGE}'"
  fi
  echo "[$(date +%H:%M:%S)] Network started successfully." >&2
fi

# ---- Step 2: Disable bridge-nf-call-iptables ----
BRIDGE_NF_FILE="/proc/sys/net/bridge/bridge-nf-call-iptables"
if [ -f "${BRIDGE_NF_FILE}" ] && [ "$(cat "${BRIDGE_NF_FILE}")" = "1" ]; then
  echo "[$(date +%H:%M:%S)] Disabling bridge-nf-call-iptables for VM-to-VM traffic..." >&2
  if [ -n "${ROOT_PASSWORD:-}" ]; then
    echo "${ROOT_PASSWORD}" | sudo -S sysctl -w net.bridge.bridge-nf-call-iptables=0 &>/dev/null
    echo "${ROOT_PASSWORD}" | sudo -S sysctl -w net.bridge.bridge-nf-call-ip6tables=0 &>/dev/null
    echo "${ROOT_PASSWORD}" | sudo -S sysctl -w net.bridge.bridge-nf-call-arptables=0 &>/dev/null
    sudo tee /etc/sysctl.d/99-bridge-nf-call.conf > /dev/null <<'SYSEOF'
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
SYSEOF
  else
    echo "[$(date +%H:%M:%S)] WARNING: ROOT_PASSWORD not set, skipping sysctl changes" >&2
  fi
else
  echo "[$(date +%H:%M:%S)] bridge-nf-call-iptables already disabled." >&2
fi

# ---- Step 3: Verify ----
if virsh -c qemu:///system net-info "${BRIDGE}" &>/dev/null; then
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' is active and ready." >&2
  exit 0
else
  die "Network '${BRIDGE}' is not active"
fi
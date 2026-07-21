#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-bridge.sh — Create libvirt bridge network for the HPA cluster
# Supports both system libvirt (with ROOT_PASSWORD) and L2 mode
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$(cd "${SCRIPT_DIR}/../../.." && pwd)/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a; source "${ENV_FILE}"; set +a
fi

: "${DEV_BRIDGE_NAME:?Required env var DEV_BRIDGE_NAME not set}"
: "${DEV_CIDR_BLOCK:?Required env var DEV_CIDR_BLOCK not set}"

BRIDGE="${DEV_BRIDGE_NAME}"
CIDR="${DEV_CIDR_BLOCK}"
GATEWAY="${CIDR%.*}.1"
DHCP_START="${DHCP_START:-${CIDR%.*}.10}"
DHCP_END="${DHCP_END:-${CIDR%.*}.200}"

# ---- DHCP host entries ----
DHCP_HOSTS=()
gen_mac() { local ip="$1"; local last=$(echo "$ip" | awk -F. '{print $4}'); printf "52:54:00:fd:%02x:%02x" $((last >> 8)) $((last & 0xff)); }
for i in $(seq 0 $((DEV_CP_COUNT - 1))); do
  IP="${CIDR%.*}.$((100 + i))"
  DHCP_HOSTS+=("${DEV_NODE_PREFIX}-cp-${i}|$(gen_mac $IP)|$IP")
done
for i in $(seq 0 $((DEV_WORKER_COUNT - 1))); do
  IP="${CIDR%.*}.$((110 + i))"
  DHCP_HOSTS+=("${DEV_NODE_PREFIX}-worker-${i}|$(gen_mac $IP)|$IP")
done

# ---- Parse CLI overrides ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge)       BRIDGE="$2"; shift 2 ;;
    --cidr)         CIDR="$2"; shift 2 ;;
    --gateway)      GATEWAY="$2"; shift 2 ;;
    --dhcp-start)   DHCP_START="$2"; shift 2 ;;
    --dhcp-end)     DHCP_END="$2"; shift 2 ;;
    *)              echo "[$(date +%H:%M:%S)] ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---- Validate CIDR ----
CIDR_PREFIX="${CIDR#*/}"
case "$CIDR_PREFIX" in
  8|16|24|25|26|27|28|29|30) : ;;
  *) echo "[$(date +%H:%M:%S)] ERROR: Unsupported CIDR prefix /${CIDR_PREFIX}." >&2; exit 1 ;;
esac
NETWORK_ADDR="${CIDR%/*}"

# ---- Check/create network ----
echo "[$(date +%H:%M:%S)] Checking network '${BRIDGE}'..." >&2

if virsh -c qemu:///system net-info "${BRIDGE}" &>/dev/null; then
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' exists. Verifying DHCP hosts..." >&2
  for entry in "${DHCP_HOSTS[@]}"; do
    IFS='|' read -r name mac ip <<< "$entry"
    if virsh -c qemu:///system net-dumpxml "${BRIDGE}" 2>/dev/null | grep -q "mac='${mac}'"; then
      echo "[$(date +%H:%M:%S)]   DHCP host '${name}' (${mac} -> ${ip}) already present, skipping." >&2
      continue
    fi
    echo "[$(date +%H:%M:%S)]   Adding L2 static DHCP host: ${name} (${mac} -> ${ip})" >&2
    virsh -c qemu:///system net-update "${BRIDGE}" add-last ip-dhcp-host \
      "<host name='${name}' mac='${mac}' ip='${ip}'/>" --config 2>/dev/null || true
  done
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' DHCP hosts verified." >&2
else
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' not found. Creating..." >&2

  DHCP_FULL_START="${DHCP_START}"
  DHCP_FULL_END="${DHCP_END}"
  [[ "${DHCP_START}" == .* ]] && DHCP_FULL_START="${NETWORK_ADDR%.*}${DHCP_START}"
  [[ "${DHCP_END}" == .* ]] && DHCP_FULL_END="${NETWORK_ADDR%.*}${DHCP_END}"

  NET_XML=$(mktemp /tmp/hpa-bridge-net-XXXXXX.xml)
  trap 'rm -f "${NET_XML}"' EXIT

  HOST_XML=""
  for entry in "${DHCP_HOSTS[@]}"; do
    IFS='|' read -r name mac ip <<< "$entry"
    HOST_XML+="      <host name='${name}' mac='${mac}' ip='${ip}'/>"$'\n'
  done

  cat > "${NET_XML}" <<EOF
<network>
  <name>${BRIDGE}</name>
  <forward mode='bridge'/>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='${GATEWAY}' netmask='${NETMASK}'>
    <dhcp>
      <range start='${DHCP_FULL_START}' end='${DHCP_FULL_END}'/>
${HOST_XML}    </dhcp>
  </ip>
</network>
EOF

  echo "[$(date +%H:%M:%S)] Defining network '${BRIDGE}' from XML..." >&2
  virsh -c qemu:///system net-define "${NET_XML}" &>/dev/null
  echo "[$(date +%H:%M:%S)] Starting network '${BRIDGE}'..." >&2
  virsh -c qemu:///system net-start "${BRIDGE}" &>/dev/null
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
virsh -c qemu:///system net-info "${BRIDGE}" &>/dev/null
echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' is active and ready." >&2
exit 0
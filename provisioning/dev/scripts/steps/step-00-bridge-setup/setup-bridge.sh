#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-bridge.sh — Create libvirt bridge network for the HPA cluster
# Supports both system libvirt (with ROOT_PASSWORD) and L2 mode
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/../../misc/preamble.sh"

: "${DEV_BRIDGE_NAME:?Required env var DEV_BRIDGE_NAME not set}"
: "${DEV_CIDR_BLOCK:?Required env var DEV_CIDR_BLOCK not set}"

: "${DEV_NODE_PREFIX:=hpa-node}"
: "${DEV_CP_COUNT:=1}"
: "${DEV_WORKER_COUNT:=3}"
: "${DEV_DHCP_ENABLED:=true}"
: "${DEV_DHCP_START:=}"
: "${DEV_DHCP_END:=}"

BRIDGE="${DEV_BRIDGE_NAME}"

# ---- Parse CLI overrides ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge)       BRIDGE="$2"; shift 2 ;;
    --host-iface)   HOST_IFACE="$2"; shift 2 ;;
    *)              echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---- Resolve host interface for explicit bridge attachment ----
HOST_IFACE="${DEV_HOST_IFACE:-${HOST_IFACE:-}}"
if [ -z "${HOST_IFACE}" ]; then
  HOST_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' 2>/dev/null || true)"
fi

if [ -z "${HOST_IFACE}" ] || ! ip link show "${HOST_IFACE}" &>/dev/null; then
  die "No usable host interface found for ${BRIDGE}. Set DEV_HOST_IFACE (for example: eth0, ens3, enp6s0f3u1)."
fi

echo "[$(date +%H:%M:%S)] Using host interface '${HOST_IFACE}' for bridge '${BRIDGE}'." >&2

# ---- XML helpers ----
escape_xml() {
  printf '%s' "$1" | sed "s/'/'\&apos;/g"
}

run_as_root() {
  if command -v sudo &>/dev/null && sudo -n true &>/dev/null; then
    sudo "$@"
  elif [ -n "${ROOT_PASSWORD:-}" ]; then
    echo "${ROOT_PASSWORD}" | sudo -S "$@"
  else
    die "Cannot run as root; set ROOT_PASSWORD or run with sudo-capable privileges"
  fi
}

cidr_prefix() {
  local cidr_block="${1:-}"
  local prefix="${cidr_block#*/}"
  if [ "${prefix}" = "${cidr_block}" ]; then
    printf '24\n'
  else
    printf '%s\n' "${prefix}"
  fi
}

cidr_host() {
  local cidr_block="${1:-}"
  local offset="${2:-0}"
  python3 - "$cidr_block" "$offset" <<'PY'
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
offset = int(sys.argv[2])
print(network.network_address + offset)
PY
}

mac_for_ip() {
  local ip_value="${1:-}"
  python3 - "$ip_value" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
print(f"52:54:00:fd:00:{(int(ip) & 0xff):02x}")
PY
}

BUILD_DHCP_XML() {
  local cidr_block="${1:-}"
  local cp_count="${2:-1}"
  local worker_count="${3:-3}"
  local dhcp_start="${DEV_DHCP_START:-}"
  local dhcp_end="${DEV_DHCP_END:-}"

  python3 - "$cidr_block" "$cp_count" "$worker_count" "$dhcp_start" "$dhcp_end" <<'PY'
import ipaddress, sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
cp_count = int(sys.argv[2])
worker_count = int(sys.argv[3])
dhcp_start = sys.argv[4]
dhcp_end = sys.argv[5]

cp_base = 100
worker_base = 110

base = network.network_address
if dhcp_start:
    start = ipaddress.ip_address(dhcp_start)
else:
    start = base + cp_base
if dhcp_end:
    end = ipaddress.ip_address(dhcp_end)
else:
    end = base + 200

if start < base or end > network.broadcast_address or start > end:
    raise SystemExit(1)

print("  <dhcp>")
print(f"    <range start='{start}' end='{end}'/>")
for i in range(cp_count):
    ip = base + cp_base + i
    if ip > end:
        break
    mac = f"52:54:00:fd:00:{(int(ip) & 0xff):02x}"
    print(f"      <host mac='{mac}' ip='{ip}'/>")
for i in range(worker_count):
    ip = base + worker_base + i
    if ip > end:
        break
    mac = f"52:54:00:fd:00:{(int(ip) & 0xff):02x}"
    print(f"      <host mac='{mac}' ip='{ip}'/>")
print("  </dhcp>")
PY
}

BUILD_DNSMASQ_HOSTS() {
  local cidr_block="${1:-}"
  local cp_count="${2:-1}"
  local worker_count="${3:-3}"
  local dhcp_start="${DEV_DHCP_START:-}"
  local dhcp_end="${DEV_DHCP_END:-}"

  python3 - "$cidr_block" "$cp_count" "$worker_count" "$dhcp_start" "$dhcp_end" <<'PY'
import ipaddress, sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
cp_count = int(sys.argv[2])
worker_count = int(sys.argv[3])
dhcp_start = sys.argv[4]
dhcp_end = sys.argv[5]

cp_base = 100
worker_base = 110

base = network.network_address
if dhcp_start:
    start = ipaddress.ip_address(dhcp_start)
else:
    start = base + cp_base
if dhcp_end:
    end = ipaddress.ip_address(dhcp_end)
else:
    end = base + 200

if start < base or end > network.broadcast_address or start > end:
    raise SystemExit(1)

for i in range(cp_count):
    ip = base + cp_base + i
    if ip > end:
        break
    mac = f"52:54:00:fd:00:{(int(ip) & 0xff):02x}"
    print(f"dhcp-host={mac},{ip}")
for i in range(worker_count):
    ip = base + worker_base + i
    if ip > end:
        break
    mac = f"52:54:00:fd:00:{(int(ip) & 0xff):02x}"
    print(f"dhcp-host={mac},{ip}")
PY
}

BUILD_BRIDGE_XML() {
  local bridge="$1"
  local hostdev="$2"
  local dhcp_xml=""

  if [ "${DEV_DHCP_ENABLED}" = "true" ]; then
    dhcp_xml="$(BUILD_DHCP_XML "${DEV_CIDR_BLOCK}" "${DEV_CP_COUNT}" "${DEV_WORKER_COUNT}")"
  fi

  cat <<EOF_XML
<network>
  <name>${bridge}</name>
  <forward mode='bridge'/>
  <bridge name='${hostdev}'/>
${dhcp_xml}
</network>
EOF_XML
}

DEFINE_BRIDGE_NETWORK() {
  local bridge="$1"
  local hostdev="$2"
  local NET_XML

  NET_XML="$(mktemp /tmp/${bridge}-net-XXXXXX.xml)"
  BUILD_BRIDGE_XML "${bridge}" "${hostdev}" > "${NET_XML}"

  echo "[$(date +%H:%M:%S)] Defining network '${bridge}' from XML..." >&2
  if ! virsh -c qemu:///system net-define "${NET_XML}" 2>&1; then
    die "Failed to define network '${bridge}'"
  fi

  echo "[$(date +%H:%M:%S)] Starting network '${bridge}'..." >&2
  if ! virsh -c qemu:///system net-start "${bridge}" 2>&1; then
    die "Failed to start network '${bridge}'"
  fi
  echo "[$(date +%H:%M:%S)] Network started successfully." >&2
}

START_DNSMASQ() {
  local DNSMASQ_CONF="/tmp/hpa-bridge-dnsmasq.conf"
  local DNSMASQ_LEASES="/var/lib/libvirt/dnsmasq/hpa-bridge.leases"
  local DNSMASQ_PID="/var/run/dnsmasq-hpa-bridge.pid"
  local DNSMASQ_LOG="/var/log/dnsmasq-hpa-bridge.log"
  local DHCP_START="${DEV_DHCP_START:-}"
  local DHCP_END="${DEV_DHCP_END:-}"
  local RANGE_ARGS=""
  local HOST_LINES=""

  if [ "${DEV_DHCP_ENABLED}" = "true" ]; then
    if [ -n "${DHCP_START}" ] && [ -n "${DHCP_END}" ]; then
      RANGE_ARGS="dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h"
    else
      RANGE_ARGS="dhcp-range=192.168.122.100,192.168.122.200,255.255.255.0,12h"
    fi

    HOST_LINES="$(BUILD_DNSMASQ_HOSTS "${DEV_CIDR_BLOCK}" "${DEV_CP_COUNT}" "${DEV_WORKER_COUNT}")"
  fi

  if [ -f "${DNSMASQ_PID}" ] && sudo kill -0 "$(cat "${DNSMASQ_PID}")" 2>/dev/null; then
    echo "[$(date +%H:%M:%S)] Restarting dnsmasq on '${BRIDGE}'..." >&2
    sudo kill "$(cat "${DNSMASQ_PID}")" 2>/dev/null || true
    sleep 1
  fi

  run_as_root mkdir -p "$(dirname "${DNSMASQ_LEASES}")"
  sudo rm -f "${DNSMASQ_CONF}"
  sudo tee "${DNSMASQ_CONF}" >/dev/null <<EOF_CONF
interface=${BRIDGE}
bind-interfaces
except-interface=${HOST_IFACE}
except-interface=lo
dhcp-authoritative
dhcp-leasefile=${DNSMASQ_LEASES}
pid-file=${DNSMASQ_PID}
log-dhcp
log-facility=${DNSMASQ_LOG}
resolv-file=/run/systemd/resolve/resolv.conf
${RANGE_ARGS}
${HOST_LINES}
EOF_CONF

  if ! run_as_root dnsmasq --conf-file="${DNSMASQ_CONF}"; then
    die "Failed to start dnsmasq on '${BRIDGE}'"
  fi

  local LEASE_COUNT=0
  if [ -n "${HOST_LINES}" ]; then
    LEASE_COUNT="$(printf '%s\n' "${HOST_LINES}" | sed '/^$/d' | wc -l | tr -d ' ')"
  fi

  echo "[$(date +%H:%M:%S)] dnsmasq is serving DHCP on '${BRIDGE}' with ${LEASE_COUNT} static leases." >&2
}

# ---- Check/create network ----
echo "[$(date +%H:%M:%S)] Checking network '${BRIDGE}'..." >&2

if virsh -c qemu:///system net-info "${BRIDGE}" &>/dev/null; then
  EXISTING_XML="$(virsh -c qemu:///system net-dumpxml "${BRIDGE}" 2>/dev/null || true)"
  if echo "${EXISTING_XML}" | grep -q "<bridge name='${HOST_IFACE}'/>"; then
    echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' already exists with hostdev '${HOST_IFACE}'." >&2
  else
    echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' exists but lacks explicit hostdev '${HOST_IFACE}'. Redefining..." >&2
    virsh -c qemu:///system net-destroy "${BRIDGE}" 2>/dev/null || true
    virsh -c qemu:///system net-undefine "${BRIDGE}" 2>/dev/null || true
    DEFINE_BRIDGE_NETWORK "${BRIDGE}" "${HOST_IFACE}"
  fi
else
  echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' not found. Creating..." >&2
  DEFINE_BRIDGE_NETWORK "${BRIDGE}" "${HOST_IFACE}"
fi

# ---- Step 2: Assign host IP and disable bridge-nf-call-iptables ----
HOST_IP="$(cidr_host "${DEV_CIDR_BLOCK}" 1)"
HOST_PREFIX="$(cidr_prefix "${DEV_CIDR_BLOCK}")"
if ! ip addr show "${BRIDGE}" 2>/dev/null | grep -q "inet .*${HOST_IP}/${HOST_PREFIX}"; then
  echo "[$(date +%H:%M:%S)] Assigning host IP ${HOST_IP}/${HOST_PREFIX} to ${BRIDGE}..." >&2
  if command -v sudo &>/dev/null && sudo -n true &>/dev/null; then
    sudo ip addr add "${HOST_IP}/${HOST_PREFIX}" dev "${BRIDGE}"
  elif [ -n "${ROOT_PASSWORD:-}" ]; then
    echo "${ROOT_PASSWORD}" | sudo -S ip addr add "${HOST_IP}/${HOST_PREFIX}" dev "${BRIDGE}"
  else
    die "Cannot add host IP ${HOST_IP}/${HOST_PREFIX} to ${BRIDGE}; set ROOT_PASSWORD or run with sudo-capable privileges"
  fi
fi
if ! ip link show "${HOST_IFACE}" &>/dev/null; then
  die "Host interface '${HOST_IFACE}' does not exist"
fi
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

CONFIGURE_HOST_NAT() {
  local OUT_IFACE
  OUT_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' 2>/dev/null || true)"

  if [ -n "${OUT_IFACE}" ]; then
    echo "[$(date +%H:%M:%S)] Enabling IP forwarding and NAT for ${DEV_CIDR_BLOCK} via ${OUT_IFACE}..." >&2
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
    sudo iptables -t nat -C POSTROUTING -s "${DEV_CIDR_BLOCK}" -o "${OUT_IFACE}" -j MASQUERADE >/dev/null 2>&1 || \
      sudo iptables -t nat -A POSTROUTING -s "${DEV_CIDR_BLOCK}" -o "${OUT_IFACE}" -j MASQUERADE
    sudo iptables -C FORWARD -i "${BRIDGE}" -o "${OUT_IFACE}" -j ACCEPT >/dev/null 2>&1 || \
      sudo iptables -I FORWARD 1 -i "${BRIDGE}" -o "${OUT_IFACE}" -j ACCEPT
  else
    echo "[$(date +%H:%M:%S)] WARNING: unable to determine default outbound interface for NAT." >&2
  fi
}

CONFIGURE_HOST_NAT

# ---- Step 3: Start DHCP server on the bridge ----
START_DNSMASQ

# ---- Step 4: Verify ----
echo "[$(date +%H:%M:%S)] Verifying bridge '${BRIDGE}' and host interface '${HOST_IFACE}'..." >&2
if ! ip link show "${HOST_IFACE}" &>/dev/null; then
  die "Host interface '${HOST_IFACE}' does not exist"
fi
if ! virsh -c qemu:///system net-info "${BRIDGE}" &>/dev/null; then
  die "Network '${BRIDGE}' is not active"
fi
if ! virsh -c qemu:///system net-dumpxml "${BRIDGE}" | grep -q "<bridge name='${HOST_IFACE}'/>"; then
  die "Network '${BRIDGE}' does not reference bridge '${HOST_IFACE}'"
fi
if ! ip addr show "${BRIDGE}" 2>/dev/null | grep -q "inet .*${HOST_IP}/${HOST_PREFIX}"; then
  die "Bridge '${BRIDGE}' does not have IP ${HOST_IP}/${HOST_PREFIX}"
fi
if [ "${DEV_DHCP_ENABLED}" = "true" ] && ! pgrep -f "dnsmasq.*hpa-bridge" >/dev/null; then
  die "dnsmasq is not running for '${BRIDGE}'"
fi

echo "[$(date +%H:%M:%S)] Network '${BRIDGE}' is active and ready on host interface '${HOST_IFACE}' (${HOST_IP}/${HOST_PREFIX})." >&2
exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# virsh-provision.sh — Manual VM provisioning using virsh commands
#
# This is Option E - a fallback approach when Terraform libvirt provider
# fails to properly manage VM lifecycle. This script creates VMs directly
# using virsh XML definitions.
#
# Usage: ./virsh-provision.sh [--destroy]
#
# Options:
#   --destroy    Destroy all VMs and exit
# ---------------------------------------------------------------------------
set -euo pipefail

# Source preamble for logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# Configuration
CLUSTER_NAME="hpa-dev"
NETWORK_NAME="hpa-bridge"
POOL_NAME="default"
DISK_PATH="/var/lib/libvirt/images"
# TALOS_ISO not needed - raw images have Talos pre-installed

# Node configuration
CP_NODES=("hpa-node-cp-0")
WORKER_NODES=("hpa-node-worker-0" "hpa-node-worker-1" "hpa-node-worker-2")
ALL_NODES=("${CP_NODES[@]}" "${WORKER_NODES[@]}")

# IP configuration
declare -A NODE_IPS
NODE_IPS["hpa-node-cp-0"]="192.168.122.100"
NODE_IPS["hpa-node-worker-0"]="192.168.122.110"
NODE_IPS["hpa-node-worker-1"]="192.168.122.111"
NODE_IPS["hpa-node-worker-2"]="192.168.122.112"

# MAC addresses (from Terraform locals)
declare -A NODE_MACS
NODE_MACS["hpa-node-cp-0"]="52:54:00:fd:00:64"
NODE_MACS["hpa-node-worker-0"]="52:54:00:fd:00:6e"
NODE_MACS["hpa-node-worker-1"]="52:54:00:fd:00:6f"
NODE_MACS["hpa-node-worker-2"]="52:54:00:fd:00:70"

# Parse arguments
DESTROY=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --destroy|-d)
      DESTROY=true
      shift
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# Destroy function
destroy_vms() {
  STEP_START "Destroying VMs"
  
  for node in "${ALL_NODES[@]}"; do
    echo "Destroying $node..."
    virsh destroy "$node" 2>/dev/null || true
    virsh undefine "$node" --remove-all-volumes 2>/dev/null || true
  done
  
  STEP_END "Destroying VMs"
  echo "VMs destroyed"
  exit 0
}

# Create VM XML definition
create_vm_xml() {
  local node="$1"
  local ip="${NODE_IPS[$node]}"
  local mac="${NODE_MACS[$node]}"
  local is_worker="$2"
  
  local disk_path="${is_worker}"
  if [[ "$is_worker" == "true" ]]; then
    disk_path="vdb"
  fi
  
  cat <<EOF
<domain type='kvm'>
  <name>${node}</name>
  <memory unit='MiB'>${MEMORY:-2048}</memory>
  <currentMemory unit='MiB'>${MEMORY:-2048}</currentMemory>
  <vcpu placement='static'>${VCPU:-2}</vcpu>
  
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  
  <features>
    <acpi/>
  </features>
  
  <cpu mode='host-passthrough'/>
  
  <devices>
    <!-- OS Disk -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
      <source file='${DISK_PATH}/${node}-os.raw'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    
    <!-- Ceph Disk for Workers -->
$(if [[ "$is_worker" == "true" ]]; then
cat <<CEPHDISK
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
      <source file='/var/lib/libvirt/images/ceph-disks/${node}-ceph.img'/>
      <target dev='vdb' bus='virtio'/>
    </disk>
CEPHDISK
fi)
    
    <!-- Network Interface -->
    <interface type='bridge'>
      <source bridge='${NETWORK_NAME}'/>
      <model type='virtio'/>
      <mac address='${mac}'/>
    </interface>
    
    <!-- Serial Console -->
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
EOF
}

# Main function
main() {
  if [[ "$DESTROY" == "true" ]]; then
    destroy_vms
  fi
  
  STEP_START "Manual VM provisioning (Option E)"
  
  # Check prerequisites - raw images must exist
  # Talos ISO not needed because raw images have Talos pre-installed
  for node in "${ALL_NODES[@]}"; do
    if [[ ! -f "${DISK_PATH}/${node}-os.raw" ]]; then
      die "Disk image not found for $node at ${DISK_PATH}/${node}-os.raw"
    fi
  done
  
  for node in "${ALL_NODES[@]}"; do
    if [[ ! -f "${DISK_PATH}/${node}-os.raw" ]]; then
      die "Disk image not found for $node at ${DISK_PATH}/${node}-os.raw"
    fi
  done
  
  # Check if network exists
  if ! virsh net-list --all | grep -q "$NETWORK_NAME"; then
    die "Network $NETWORK_NAME not found. Run steps/step-01-bridge-setup/setup-bridge.sh first."
  fi
  
  # Create Ceph disks for workers if they don't exist
  mkdir -p /var/lib/libvirt/images/ceph-disks
  for worker in "${WORKER_NODES[@]}"; do
    local ceph_img="/var/lib/libvirt/images/ceph-disks/${worker}-ceph.img"
    if [[ ! -f "$ceph_img" ]]; then
      log "Creating Ceph disk for $worker..."
      truncate -s 20G "$ceph_img"
      chown qemu:qemu "$ceph_img" 2>/dev/null || true
    fi
  done
  
  # Define and create VMs
  for node in "${ALL_NODES[@]}"; do
    local is_worker="false"
    if [[ " ${WORKER_NODES[*]} " =~ " ${node} " ]]; then
      is_worker="true"
    fi
    
    # Skip CP for memory/cpu settings
    if [[ "$is_worker" == "true" ]]; then
      MEMORY=2048
      VCPU=2
    else
      MEMORY=4096
      VCPU=2
    fi
    
    log "Creating VM: $node"
    
    # Create XML definition
    local xml_file="/tmp/${node}.xml"
    create_vm_xml "$node" "$is_worker" > "$xml_file"
    
    # Define domain
    virsh define "$xml_file"
    rm -f "$xml_file"
    
    # Start VM
    virsh start "$node"
  done
  
  STEP_END "Manual VM provisioning"
  
  echo ""
  echo "=== VMs Created ==="
  virsh list --all
  
  echo ""
  echo "VM provisioning complete."
  echo "Next steps:"
  echo "  1. Wait for Talos API (port 50000) to be available on each node"
  echo "  2. Run: talosctl apply-config --nodes <node-ip> --file <machine-config>"
  echo "  3. Bootstrap: talosctl bootstrap --endpoints <cp-ip>:50000 --nodes <cp-ip>"
}

main "$@"
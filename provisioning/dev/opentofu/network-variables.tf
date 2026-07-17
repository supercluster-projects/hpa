# Network Variables - Single Source of Truth
# This file centralizes all network-related configurations to avoid DRY violations

# ---------------------------------------------------------------------------
# Network Configuration
# ---------------------------------------------------------------------------

locals {
  # Canonical network values - all other values derive from these
  cidr_base   = "192.168.122.0"
  cidr_block  = var.DEV_CIDR_BLOCK
  gateway     = cidrhost(local.cidr_block, 1)
  dns_servers = [local.gateway]
  cidr_prefix = split("/", var.DEV_CIDR_BLOCK)[1]

  # ---------------------------------------------------------------------------
  # IP Address Management
  # ---------------------------------------------------------------------------

  # Control Plane IPs (starting at offset 100)
  cp_ip_base = 100
  cp_ips = [
    for i in range(var.DEV_CP_COUNT) : cidrhost(local.cidr_block, local.cp_ip_base + i)
  ]

  # Worker Node IPs (starting at offset 110)
  worker_ip_base = 110
  worker_ips = [
    for i in range(var.DEV_WORKER_COUNT) : cidrhost(local.cidr_block, local.worker_ip_base + i)
  ]

  # All node IPs
  all_ips = concat(local.cp_ips, local.worker_ips)

  # ---------------------------------------------------------------------------
  # LoadBalancer IP Pool
  # ---------------------------------------------------------------------------

  # LB pool is the last /28 of the cluster network (192.168.122.208/28)
  lb_pool_cidr = cidrsubnet(local.cidr_block, 4, 13)
  first_lb_ip  = cidrhost(local.lb_pool_cidr, 2)

  # ---------------------------------------------------------------------------
  # Node Names
  # ---------------------------------------------------------------------------

  cp_node_names     = [for i in range(var.DEV_CP_COUNT) : "${var.DEV_NODE_PREFIX}-cp-${i}"]
  worker_node_names = [for i in range(var.DEV_WORKER_COUNT) : "${var.DEV_NODE_PREFIX}-worker-${i}"]
  all_node_names    = concat(local.cp_node_names, local.worker_node_names)

  # ---------------------------------------------------------------------------
  # Node Type Classification
  # ---------------------------------------------------------------------------

  node_types = merge(
    { for name in local.cp_node_names : name => "controlplane" },
    { for name in local.worker_node_names : name => "worker" },
  )

  # ---------------------------------------------------------------------------
  # IP Address Lookup by Node Name
  # ---------------------------------------------------------------------------

  node_ips = merge(
    { for i, name in local.cp_node_names : name => local.cp_ips[i] },
    { for i, name in local.worker_node_names : name => local.worker_ips[i] },
  )

  # ---------------------------------------------------------------------------
  # Node Metadata for Iteration
  # ---------------------------------------------------------------------------

  node_apply = {
    for name in local.all_node_names : name => {
      type = local.node_types[name]
      ip   = local.node_ips[name]
    }
  }

  # ---------------------------------------------------------------------------
  # MAC Addresses for Static DHCP
  # ---------------------------------------------------------------------------

  # Format: 52:54:00:fd:00:<last-octet-hex>
  # Required so Talos gets the expected IP from DHCP on first boot
  node_macs = {
    for name, info in local.node_apply : name => format("52:54:00:fd:00:%02x", split(".", info.ip)[3])
  }

  # ---------------------------------------------------------------------------
  # Cluster Endpoint
  # ---------------------------------------------------------------------------

  cluster_endpoint = "https://${local.cp_ips[0]}:6443"

  # ---------------------------------------------------------------------------
  # Talos Image Factory
  # ---------------------------------------------------------------------------

  # Schematic ID: zero schematic (no customization)
  talos_schematic_id = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"

  # ISO image URL
  iso_url = "${var.DEV_TALOS_IMAGE_FACTORY_URL}/${local.talos_schematic_id}/${var.TALOS_VERSION}/metal-amd64.iso"
}
# Local computed values for the Talos cluster provisioning
# Defines node naming, IP assignment, cluster endpoint, and base image URL.

locals {
  # Node names: control plane and worker nodes
  cp_node_names     = [for i in range(var.DEV_CP_COUNT) : "${var.DEV_NODE_PREFIX}-cp-${i}"]
  worker_node_names = [for i in range(var.DEV_WORKER_COUNT) : "${var.DEV_NODE_PREFIX}-worker-${i}"]
  all_node_names    = concat(local.cp_node_names, local.worker_node_names)

  # Static IP assignment for each node within the cluster CIDR
  # Control plane: .100, .101, ...; Workers: .110, .111, ...
  cp_ips     = [for i in range(var.DEV_CP_COUNT) : cidrhost(var.DEV_CIDR_BLOCK, 100 + i)]
  worker_ips = [for i in range(var.DEV_WORKER_COUNT) : cidrhost(var.DEV_CIDR_BLOCK, 110 + i)]
  all_ips    = concat(local.cp_ips, local.worker_ips)

  # Kubernetes API endpoint on the first control plane node
  cluster_endpoint = "https://${local.cp_ips[0]}:6443"

  # Gateway and DNS derived from DEV_CIDR_BLOCK (first host + first host)
  gateway     = cidrhost(var.DEV_CIDR_BLOCK, 1)
  dns_servers = [local.gateway]

  # Node type classification: controlplane or worker
  node_types = merge(
    { for name in local.cp_node_names : name => "controlplane" },
    { for name in local.worker_node_names : name => "worker" },
  )

  # IP address lookup by node name
  node_ips = merge(
    { for i, name in local.cp_node_names : name => local.cp_ips[i] },
    { for i, name in local.worker_node_names : name => local.worker_ips[i] },
  )

  # Aggregated node metadata for for_each iteration over all nodes
  node_apply = {
    for name in local.all_node_names : name => {
      type = local.node_types[name]
      ip   = local.node_ips[name]
    }
  }

  # LB pool CIDR: the last /28 of the cluster network for LoadBalancer IPs
  # Derived from DEV_CIDR_BLOCK so the two never diverge.
  # cidrsubnet(/24, 4, 13) -> 192.168.122.208/28 (range .208-.223)
  lb_pool_cidr = cidrsubnet(var.DEV_CIDR_BLOCK, 4, 13)
  # Suggested Envoy LB IP (2nd usable address in the LB pool, after network .208)
  # Actual IP is assigned dynamically by Cilium; this is a convenience default.
  first_lb_ip = cidrhost(local.lb_pool_cidr, 2)

  # Deterministic MAC addresses matching static DHCP host entries in hpa-bridge
  # Format: 52:54:00:fd:00:<last-octet-hex>
  # Required so Talos gets the expected IP from DHCP on first boot,
  # enabling talos_machine_configuration_apply to connect.
  node_macs = {
    for name, info in local.node_apply : name => format("52:54:00:fd:00:%02x", split(".", info.ip)[3])
  }

  # Base image URL for the Talos metal qcow2 image from the image factory
  # Uses the "zero" schematic (no customization) matching the selected Talos version
  # Schematic ID: 376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba (official well-known zero schematic)
  talos_schematic_id = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
  iso_url            = "${var.DEV_TALOS_IMAGE_FACTORY_URL}/${local.talos_schematic_id}/${var.TALOS_VERSION}/metal-amd64.qcow2"
}

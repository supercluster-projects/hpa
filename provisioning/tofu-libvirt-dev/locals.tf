# Local computed values for the Talos cluster provisioning
# Defines node naming, IP assignment, cluster endpoint, and base image URL.

locals {
  # Node names: control plane and worker nodes
  cp_node_names     = [for i in range(var.CP_COUNT) : "${var.NODE_PREFIX}-cp-${i}"]
  worker_node_names = [for i in range(var.WORKER_COUNT) : "${var.NODE_PREFIX}-worker-${i}"]
  all_node_names    = concat(local.cp_node_names, local.worker_node_names)

  # Static IP assignment for each node within the cluster CIDR
  # Control plane: .100, .101, ...; Workers: .110, .111, ...
  cp_ips     = [for i in range(var.CP_COUNT) : cidrhost(var.CIDR_BLOCK, 100 + i)]
  worker_ips = [for i in range(var.WORKER_COUNT) : cidrhost(var.CIDR_BLOCK, 110 + i)]
  all_ips    = concat(local.cp_ips, local.worker_ips)

  # Kubernetes API endpoint on the first control plane node
  cluster_endpoint = "https://${local.cp_ips[0]}:6443"

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

  # Base image URL for the Talos metal qcow2 image from the image factory
  # Uses the "zero" schematic (no customization) matching the selected Talos version
  # Schematic ID: 376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba (official well-known zero schematic)
  talos_schematic_id = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
  iso_url            = "${var.TALOS_IMAGE_FACTORY_URL}/${local.talos_schematic_id}/${var.TALOS_VERSION}/metal-amd64.qcow2"
}

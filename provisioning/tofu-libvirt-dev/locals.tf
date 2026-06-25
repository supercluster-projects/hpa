# Local computed values for the Talos cluster provisioning
# Defines node naming, IP assignment, cluster endpoint, and base image URL.

locals {
  # Node names: control plane and worker nodes
  cp_node_names     = [for i in range(var.cp_count) : "${var.node_prefix}-cp-${i}"]
  worker_node_names = [for i in range(var.worker_count) : "${var.node_prefix}-worker-${i}"]
  all_node_names    = concat(local.cp_node_names, local.worker_node_names)

  # Static IP assignment for each node within the cluster CIDR
  # Control plane: .100, .101, ...; Workers: .110, .111, ...
  cp_ips     = [for i in range(var.cp_count) : cidrhost(var.cidr_block, 100 + i)]
  worker_ips = [for i in range(var.worker_count) : cidrhost(var.cidr_block, 110 + i)]
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
  # Schematic ID: 376567988ad370138cb8fc01d4c6144a9e3c1a4f32a8e1b0925e7e90c8c1f2e2
  talos_schematic_id = "376567988ad370138cb8fc01d4c6144a9e3c1a4f32a8e1b0925e7e90c8c1f2e2"
  iso_url            = "${var.talos_image_factory_url}/${local.talos_schematic_id}/${var.talos_version}/metal-amd64.qcow2"
}

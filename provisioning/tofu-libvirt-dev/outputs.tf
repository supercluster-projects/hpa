# Outputs for the Talos cluster provisioning
# Exposes connection details and node inventory for downstream use.

output "kubeconfig" {
  description = "Admin kubeconfig for the Talos cluster (sensitive)"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client configuration for the cluster (sensitive)"
  value       = data.talos_client_configuration.this.client_configuration
  sensitive   = true
}

output "cp_ips" {
  description = "IP addresses of the control plane nodes"
  value       = local.cp_ips
}

output "worker_ips" {
  description = "IP addresses of the worker nodes"
  value       = local.worker_ips
}

output "all_node_ips" {
  description = "IP addresses of all cluster nodes"
  value       = local.all_ips
}

output "node_count" {
  description = "Total number of nodes in the cluster"
  value       = var.CP_COUNT + var.WORKER_COUNT
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
  value       = local.cluster_endpoint
}

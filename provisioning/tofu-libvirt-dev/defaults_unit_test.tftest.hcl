# Unit tests for the Talos cluster provisioning module
# Validates default variable values, VM naming convention, provider URIs,
# and variable validation rules in plan mode (no real infrastructure needed).

run "test_default_variable_values" {
  command = plan

  assert {
    condition     = var.cp_count == 1
    error_message = "Default cp_count must be 1, got ${var.cp_count}"
  }

  assert {
    condition     = var.worker_count == 3
    error_message = "Default worker_count must be 3, got ${var.worker_count}"
  }

  assert {
    condition     = var.os_disk_size_gb == 20
    error_message = "Default os_disk_size_gb must be 20, got ${var.os_disk_size_gb}"
  }

  assert {
    condition     = var.ceph_disk_size_gb == 20
    error_message = "Default ceph_disk_size_gb must be 20, got ${var.ceph_disk_size_gb}"
  }

  assert {
    condition     = var.bridge_name == "hpa-bridge"
    error_message = "Default bridge_name must be 'hpa-bridge', got '${var.bridge_name}'"
  }

  assert {
    condition     = can(regex("^v", var.talos_version))
    error_message = "Default talos_version '${var.talos_version}' does not start with 'v'"
  }
}

run "test_vm_naming_convention" {
  command = plan

  assert {
    condition     = length(local.cp_node_names) == 1 && local.cp_node_names[0] == "${var.node_prefix}-cp-0"
    error_message = "Control plane node name does not follow node_prefix-cp-N convention: got ${join(", ", local.cp_node_names)}"
  }

  assert {
    condition     = length(local.worker_node_names) == 3
    error_message = "Expected 3 worker node names, got ${length(local.worker_node_names)}"
  }

  assert {
    condition     = alltrue([for name in local.worker_node_names : can(regex("^${var.node_prefix}-worker-\\d+$", name))])
    error_message = "Worker node names do not follow node_prefix-worker-N convention: ${join(", ", local.worker_node_names)}"
  }

  assert {
    condition     = length(local.all_ips) == var.cp_count + var.worker_count
    error_message = "IP count ${length(local.all_ips)} does not match node count ${var.cp_count + var.worker_count}"
  }
}

run "test_cluster_endpoint" {
  command = plan

  assert {
    condition     = local.cluster_endpoint == "https://${local.cp_ips[0]}:6443"
    error_message = "Cluster endpoint should use first CP IP: got ${local.cluster_endpoint}"
  }

  assert {
    condition     = local.cp_ips[0] == cidrhost(var.cidr_block, 100)
    error_message = "First CP IP should be cidrhost(cidr_block, 100), got ${local.cp_ips[0]}"
  }

  assert {
    condition     = local.worker_ips[0] == cidrhost(var.cidr_block, 110)
    error_message = "First worker IP should be cidrhost(cidr_block, 110), got ${local.worker_ips[0]}"
  }
}

run "test_iso_url_format" {
  command = plan

  assert {
    condition     = can(regex("^https?://", var.talos_image_factory_url))
    error_message = "talos_image_factory_url must start with http:// or https://, got '${var.talos_image_factory_url}'"
  }

  assert {
    condition     = can(regex("/${var.talos_version}/metal-amd64\\.qcow2$", local.iso_url))
    error_message = "ISO URL '${local.iso_url}' does not end with expected version and qcow2 path"
  }
}

run "test_cidr_default" {
  command = plan

  assert {
    condition     = var.cidr_block == "192.168.122.0/24"
    error_message = "Default cidr_block must be 192.168.122.0/24, got ${var.cidr_block}"
  }

  assert {
    condition     = var.gateway == "192.168.122.1"
    error_message = "Default gateway must be 192.168.122.1, got ${var.gateway}"
  }

  assert {
    condition     = length(var.dns_servers) == 1 && var.dns_servers[0] == "192.168.122.1"
    error_message = "Default dns_servers must be [192.168.122.1], got ${jsonencode(var.dns_servers)}"
  }
}

run "test_node_count_output" {
  command = plan

  assert {
    condition     = output.node_count == var.cp_count + var.worker_count
    error_message = "node_count output ${output.node_count} != cp_count(${var.cp_count}) + worker_count(${var.worker_count})"
  }
}

run "test_negative_disk_size_fails_validation" {
  command = plan

  variables {
    os_disk_size_gb = -5
  }

  expect_failures = [
    var.os_disk_size_gb,
  ]
}

run "test_empty_bridge_name_fails_validation" {
  command = plan

  variables {
    bridge_name = ""
  }

  expect_failures = [
    var.bridge_name,
  ]
}

run "test_invalid_talos_version_fails_validation" {
  command = plan

  variables {
    talos_version = "1.0.0"
  }

  expect_failures = [
    var.talos_version,
  ]
}

run "test_node_prefix_with_uppercase_fails_validation" {
  command = plan

  variables {
    node_prefix = "Hpa-Node"
  }

  expect_failures = [
    var.node_prefix,
  ]
}

# Unit tests for the Talos cluster provisioning module
# Validates default variable values, VM naming convention, provider URIs,
# and variable validation rules in plan mode (no real infrastructure needed).

run "test_default_variable_values" {
  command = plan

  assert {
    condition     = var.CP_COUNT == 1
    error_message = "Default CP_COUNT must be 1, got ${var.CP_COUNT}"
  }

  assert {
    condition     = var.WORKER_COUNT == 3
    error_message = "Default WORKER_COUNT must be 3, got ${var.WORKER_COUNT}"
  }

  assert {
    condition     = var.OS_DISK_SIZE_GB == 20
    error_message = "Default OS_DISK_SIZE_GB must be 20, got ${var.OS_DISK_SIZE_GB}"
  }

  assert {
    condition     = var.CEPH_DISK_SIZE_GB == 20
    error_message = "Default CEPH_DISK_SIZE_GB must be 20, got ${var.CEPH_DISK_SIZE_GB}"
  }

  assert {
    condition     = var.BRIDGE_NAME == "hpa-bridge"
    error_message = "Default BRIDGE_NAME must be 'hpa-bridge', got '${var.BRIDGE_NAME}'"
  }

  assert {
    condition     = can(regex("^v", var.TALOS_VERSION))
    error_message = "Default TALOS_VERSION '${var.TALOS_VERSION}' does not start with 'v'"
  }
}

run "test_vm_naming_convention" {
  command = plan

  assert {
    condition     = length(local.cp_node_names) == 1 && local.cp_node_names[0] == "${var.NODE_PREFIX}-cp-0"
    error_message = "Control plane node name does not follow NODE_PREFIX-cp-N convention: got ${join(", ", local.cp_node_names)}"
  }

  assert {
    condition     = length(local.worker_node_names) == 3
    error_message = "Expected 3 worker node names, got ${length(local.worker_node_names)}"
  }

  assert {
    condition     = alltrue([for name in local.worker_node_names : can(regex("^${var.NODE_PREFIX}-worker-\\d+$", name))])
    error_message = "Worker node names do not follow NODE_PREFIX-worker-N convention: ${join(", ", local.worker_node_names)}"
  }

  assert {
    condition     = length(local.all_ips) == var.CP_COUNT + var.WORKER_COUNT
    error_message = "IP count ${length(local.all_ips)} does not match node count ${var.CP_COUNT + var.WORKER_COUNT}"
  }
}

run "test_cluster_endpoint" {
  command = plan

  assert {
    condition     = local.cluster_endpoint == "https://${local.cp_ips[0]}:6443"
    error_message = "Cluster endpoint should use first CP IP: got ${local.cluster_endpoint}"
  }

  assert {
    condition     = local.cp_ips[0] == cidrhost(var.CIDR_BLOCK, 100)
    error_message = "First CP IP should be cidrhost(CIDR_BLOCK, 100), got ${local.cp_ips[0]}"
  }

  assert {
    condition     = local.worker_ips[0] == cidrhost(var.CIDR_BLOCK, 110)
    error_message = "First worker IP should be cidrhost(CIDR_BLOCK, 110), got ${local.worker_ips[0]}"
  }
}

run "test_iso_url_format" {
  command = plan

  assert {
    condition     = can(regex("^https?://", var.TALOS_IMAGE_FACTORY_URL))
    error_message = "TALOS_IMAGE_FACTORY_URL must start with http:// or https://, got '${var.TALOS_IMAGE_FACTORY_URL}'"
  }

  assert {
    condition     = can(regex("/${var.TALOS_VERSION}/metal-amd64\\.qcow2$", local.iso_url))
    error_message = "ISO URL '${local.iso_url}' does not end with expected version and qcow2 path"
  }
}

run "test_cidr_default" {
  command = plan

  assert {
    condition     = var.CIDR_BLOCK == "192.168.122.0/24"
    error_message = "Default CIDR_BLOCK must be 192.168.122.0/24, got ${var.CIDR_BLOCK}"
  }

  assert {
    condition     = var.GATEWAY == "192.168.122.1"
    error_message = "Default GATEWAY must be 192.168.122.1, got ${var.GATEWAY}"
  }

  assert {
    condition     = length(var.DNS_SERVERS) == 1 && var.DNS_SERVERS[0] == "192.168.122.1"
    error_message = "Default DNS_SERVERS must be [192.168.122.1], got ${jsonencode(var.DNS_SERVERS)}"
  }
}

run "test_node_count_output" {
  command = plan

  assert {
    condition     = output.node_count == var.CP_COUNT + var.WORKER_COUNT
    error_message = "node_count output ${output.node_count} != CP_COUNT(${var.CP_COUNT}) + WORKER_COUNT(${var.WORKER_COUNT})"
  }
}

run "test_negative_disk_size_fails_validation" {
  command = plan

  variables {
    OS_DISK_SIZE_GB = -5
  }

  expect_failures = [
    var.OS_DISK_SIZE_GB,
  ]
}

run "test_empty_bridge_name_fails_validation" {
  command = plan

  variables {
    BRIDGE_NAME = ""
  }

  expect_failures = [
    var.BRIDGE_NAME,
  ]
}

run "test_invalid_talos_version_fails_validation" {
  command = plan

  variables {
    TALOS_VERSION = "1.0.0"
  }

  expect_failures = [
    var.TALOS_VERSION,
  ]
}

run "test_node_prefix_with_uppercase_fails_validation" {
  command = plan

  variables {
    NODE_PREFIX = "Hpa-Node"
  }

  expect_failures = [
    var.NODE_PREFIX,
  ]
}

# Unit tests for the Talos cluster provisioning module
# All variables must be explicitly set (no defaults). Tests validate
# naming conventions, derived locals, CIDR math, and validation rules.

run "test_vm_naming_convention" {
  command = plan

  variables {
    DEV_CLUSTER_NAME            = "hpa-dev"
    DEV_CP_COUNT                = 1
    DEV_WORKER_COUNT            = 3
    DEV_VM_CPU                  = 2
    DEV_CP_RAM_MB               = 4096
    DEV_WORKER_RAM_MB           = 3072
    DEV_OS_DISK_SIZE_GB         = 20
    DEV_CEPH_DISK_SIZE_GB       = 20
    DEV_BRIDGE_NAME             = "hpa-bridge"
    DEV_TALOS_VERSION           = "v1.13.5"
    DEV_TALOS_IMAGE_FACTORY_URL = "https://factory.talos.dev/image"
    DEV_NODE_PREFIX             = "hpa-node"
    DEV_CIDR_BLOCK              = "192.168.122.0/24"
  }

  assert {
    condition     = length(local.cp_node_names) == 1 && local.cp_node_names[0] == "${var.DEV_NODE_PREFIX}-cp-0"
    error_message = "Control plane node name does not follow DEV_NODE_PREFIX-cp-N convention: got ${join(", ", local.cp_node_names)}"
  }

  assert {
    condition     = length(local.worker_node_names) == 3
    error_message = "Expected 3 worker node names, got ${length(local.worker_node_names)}"
  }

  assert {
    condition     = alltrue([for name in local.worker_node_names : can(regex("^${var.DEV_NODE_PREFIX}-worker-\\d+$", name))])
    error_message = "Worker node names do not follow DEV_NODE_PREFIX-worker-N convention: ${join(", ", local.worker_node_names)}"
  }

  assert {
    condition     = length(local.all_ips) == var.DEV_CP_COUNT + var.DEV_WORKER_COUNT
    error_message = "IP count ${length(local.all_ips)} does not match node count ${var.DEV_CP_COUNT + var.DEV_WORKER_COUNT}"
  }
}

run "test_cluster_endpoint_and_cidr" {
  command = plan

  variables {
    DEV_CLUSTER_NAME            = "hpa-dev"
    DEV_CP_COUNT                = 1
    DEV_WORKER_COUNT            = 3
    DEV_VM_CPU                  = 2
    DEV_CP_RAM_MB               = 4096
    DEV_WORKER_RAM_MB           = 3072
    DEV_OS_DISK_SIZE_GB         = 20
    DEV_CEPH_DISK_SIZE_GB       = 20
    DEV_BRIDGE_NAME             = "hpa-bridge"
    DEV_TALOS_VERSION           = "v1.13.5"
    DEV_TALOS_IMAGE_FACTORY_URL = "https://factory.talos.dev/image"
    DEV_NODE_PREFIX             = "hpa-node"
    DEV_CIDR_BLOCK              = "192.168.122.0/24"
  }

  assert {
    condition     = local.cluster_endpoint == "https://${local.cp_ips[0]}:6443"
    error_message = "Cluster endpoint should use first CP IP: got ${local.cluster_endpoint}"
  }

  assert {
    condition     = local.cp_ips[0] == cidrhost(var.DEV_CIDR_BLOCK, 100)
    error_message = "First CP IP should be cidrhost(DEV_CIDR_BLOCK, 100), got ${local.cp_ips[0]}"
  }

  assert {
    condition     = local.worker_ips[0] == cidrhost(var.DEV_CIDR_BLOCK, 110)
    error_message = "First worker IP should be cidrhost(DEV_CIDR_BLOCK, 110), got ${local.worker_ips[0]}"
  }

  assert {
    condition     = local.gateway == cidrhost(var.DEV_CIDR_BLOCK, 1)
    error_message = "Gateway should be cidrhost(DEV_CIDR_BLOCK, 1), got ${local.gateway}"
  }

  assert {
    condition     = length(local.dns_servers) == 1 && local.dns_servers[0] == local.gateway
    error_message = "DNS servers should be [gateway], got ${jsonencode(local.dns_servers)}"
  }
}

run "test_iso_url_format" {
  command = plan

  variables {
    DEV_CLUSTER_NAME            = "hpa-dev"
    DEV_CP_COUNT                = 1
    DEV_WORKER_COUNT            = 3
    DEV_VM_CPU                  = 2
    DEV_CP_RAM_MB               = 4096
    DEV_WORKER_RAM_MB           = 3072
    DEV_OS_DISK_SIZE_GB         = 20
    DEV_CEPH_DISK_SIZE_GB       = 20
    DEV_BRIDGE_NAME             = "hpa-bridge"
    DEV_TALOS_VERSION           = "v1.13.5"
    DEV_TALOS_IMAGE_FACTORY_URL = "https://factory.talos.dev/image"
    DEV_NODE_PREFIX             = "hpa-node"
    DEV_CIDR_BLOCK              = "192.168.122.0/24"
  }

  assert {
    condition     = can(regex("^https?://", var.DEV_TALOS_IMAGE_FACTORY_URL))
    error_message = "DEV_TALOS_IMAGE_FACTORY_URL must start with http:// or https://"
  }

  assert {
    condition     = can(regex("/${var.DEV_TALOS_VERSION}/metal-amd64\\.qcow2$", local.iso_url))
    error_message = "ISO URL '${local.iso_url}' does not end with expected version and qcow2 path"
  }
}

run "test_node_count_output" {
  command = plan

  variables {
    DEV_CLUSTER_NAME            = "hpa-dev"
    DEV_CP_COUNT                = 1
    DEV_WORKER_COUNT            = 3
    DEV_VM_CPU                  = 2
    DEV_CP_RAM_MB               = 4096
    DEV_WORKER_RAM_MB           = 3072
    DEV_OS_DISK_SIZE_GB         = 20
    DEV_CEPH_DISK_SIZE_GB       = 20
    DEV_BRIDGE_NAME             = "hpa-bridge"
    DEV_TALOS_VERSION           = "v1.13.5"
    DEV_TALOS_IMAGE_FACTORY_URL = "https://factory.talos.dev/image"
    DEV_NODE_PREFIX             = "hpa-node"
    DEV_CIDR_BLOCK              = "192.168.122.0/24"
  }

  assert {
    condition     = output.node_count == var.DEV_CP_COUNT + var.DEV_WORKER_COUNT
    error_message = "node_count output ${output.node_count} != DEV_CP_COUNT(${var.DEV_CP_COUNT}) + DEV_WORKER_COUNT(${var.DEV_WORKER_COUNT})"
  }
}

run "test_negative_disk_size_fails_validation" {
  command = plan

  variables {
    DEV_CLUSTER_NAME            = "hpa-dev"
    DEV_CP_COUNT                = 1
    DEV_WORKER_COUNT            = 3
    DEV_VM_CPU                  = 2
    DEV_CP_RAM_MB               = 4096
    DEV_WORKER_RAM_MB           = 3072
    DEV_OS_DISK_SIZE_GB         = -5
    DEV_CEPH_DISK_SIZE_GB       = 20
    DEV_BRIDGE_NAME             = "hpa-bridge"
    DEV_TALOS_VERSION           = "v1.13.5"
    DEV_TALOS_IMAGE_FACTORY_URL = "https://factory.talos.dev/image"
    DEV_NODE_PREFIX             = "hpa-node"
    DEV_CIDR_BLOCK              = "192.168.122.0/24"
  }

  expect_failures = [
    var.DEV_OS_DISK_SIZE_GB,
  ]
}

run "test_empty_bridge_name_fails_validation" {
  command = plan

  variables {
    DEV_CLUSTER_NAME            = "hpa-dev"
    DEV_CP_COUNT                = 1
    DEV_WORKER_COUNT            = 3
    DEV_VM_CPU                  = 2
    DEV_CP_RAM_MB               = 4096
    DEV_WORKER_RAM_MB           = 3072
    DEV_OS_DISK_SIZE_GB         = 20
    DEV_CEPH_DISK_SIZE_GB       = 20
    DEV_BRIDGE_NAME             = ""
    DEV_TALOS_VERSION           = "v1.13.5"
    DEV_TALOS_IMAGE_FACTORY_URL = "https://factory.talos.dev/image"
    DEV_NODE_PREFIX             = "hpa-node"
    DEV_CIDR_BLOCK              = "192.168.122.0/24"
  }

  expect_failures = [
    var.DEV_BRIDGE_NAME,
  ]
}

run "test_invalid_talos_version_fails_validation" {
  command = plan

  variables {
    DEV_CLUSTER_NAME            = "hpa-dev"
    DEV_CP_COUNT                = 1
    DEV_WORKER_COUNT            = 3
    DEV_VM_CPU                  = 2
    DEV_CP_RAM_MB               = 4096
    DEV_WORKER_RAM_MB           = 3072
    DEV_OS_DISK_SIZE_GB         = 20
    DEV_CEPH_DISK_SIZE_GB       = 20
    DEV_BRIDGE_NAME             = "hpa-bridge"
    DEV_TALOS_VERSION           = "1.0.0"
    DEV_TALOS_IMAGE_FACTORY_URL = "https://factory.talos.dev/image"
    DEV_NODE_PREFIX             = "hpa-node"
    DEV_CIDR_BLOCK              = "192.168.122.0/24"
  }

  expect_failures = [
    var.DEV_TALOS_VERSION,
  ]
}

run "test_node_prefix_with_uppercase_fails_validation" {
  command = plan

  variables {
    DEV_CLUSTER_NAME            = "hpa-dev"
    DEV_CP_COUNT                = 1
    DEV_WORKER_COUNT            = 3
    DEV_VM_CPU                  = 2
    DEV_CP_RAM_MB               = 4096
    DEV_WORKER_RAM_MB           = 3072
    DEV_OS_DISK_SIZE_GB         = 20
    DEV_CEPH_DISK_SIZE_GB       = 20
    DEV_BRIDGE_NAME             = "hpa-bridge"
    DEV_TALOS_VERSION           = "v1.13.5"
    DEV_TALOS_IMAGE_FACTORY_URL = "https://factory.talos.dev/image"
    DEV_NODE_PREFIX             = "Hpa-Node"
    DEV_CIDR_BLOCK              = "192.168.122.0/24"
  }

  expect_failures = [
    var.DEV_NODE_PREFIX,
  ]
}

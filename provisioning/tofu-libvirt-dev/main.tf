# Core provisioning resources for the Talos VM cluster on libvirt/hpa-bridge
#
# Covers the full bootstrap lifecycle:
#   1. Generate machine secrets (TLS + token)
#   2. Create OS disk volumes (qcow2 from Talos image factory)
#   3. Create raw empty Ceph disk volumes for worker nodes
#   4. Define libvirt domains (VMs) with OS + ceph disks
#   5. Generate Talos machine configurations (controlplane + worker)
#   6. Apply configurations to each node
#   7. Bootstrap the first control plane node
#   8. Retrieve the cluster kubeconfig

# ---------------------------------------------------------------------------
# Step 1: Machine secrets
# ---------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {}

# ---------------------------------------------------------------------------
# Step 2a: Talos client configuration (used by apply and bootstrap resources)
# ---------------------------------------------------------------------------
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = local.all_ips
}

# ---------------------------------------------------------------------------
# Step 2b: Talos machine configuration data sources (controlplane + worker)
# ---------------------------------------------------------------------------
# These generate the base machine configuration YAML from shared patches
# (cluster-config.yaml). Per-node patches (hostname, static IP) are applied
# at the talos_machine_configuration_apply step.
data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    file("${path.module}/cluster-config.yaml"),
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  machine_type     = "worker"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    file("${path.module}/cluster-config.yaml"),
  ]
}

# ---------------------------------------------------------------------------
# Step 3: OS disk volumes (one per node, qcow2, downloaded from Talos image factory)
# ---------------------------------------------------------------------------
resource "libvirt_volume" "os_disk" {
  for_each = toset(local.all_node_names)

  name     = "${each.key}-os.qcow2"
  pool     = "default"
  capacity = var.os_disk_size_gb * 1073741824

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = {
      url = local.iso_url
    }
  }
}

# ---------------------------------------------------------------------------
# Step 4: Ceph disk volumes (one per worker node, raw, empty)
# ---------------------------------------------------------------------------
resource "libvirt_volume" "ceph_disk" {
  for_each = toset(local.worker_node_names)

  name     = "${each.key}-ceph.raw"
  pool     = "default"
  capacity = var.ceph_disk_size_gb * 1073741824

  target = {
    format = { type = "raw" }
  }
}

# ---------------------------------------------------------------------------
# Step 5: Libvirt domains (VMs)
# ---------------------------------------------------------------------------
# Each VM gets:
#   - OS disk on /dev/vda (virtio bus, qcow2)
#   - Workers also get a ceph disk on /dev/vdb (virtio bus, raw)
#   - Two virtio network interfaces (eth0, eth1) on hpa-bridge for bonding
resource "libvirt_domain" "node" {
  for_each = local.node_apply

  name        = each.key
  type        = "kvm"
  memory      = each.value.type == "controlplane" ? var.cp_ram_mb : var.worker_ram_mb
  memory_unit = "MiB"
  vcpu        = var.vm_cpu
  running     = true
  autostart   = true

  os = {
    type = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [{ dev = "hd" }]
  }

  cpu = {
    mode = "host-passthrough"
  }

  devices = {
    disks = concat(
      [
        {
          source = {
            volume = {
              pool   = "default"
              volume = libvirt_volume.os_disk[each.key].name
            }
          }
          target = {
            dev = "vda"
            bus = "virtio"
          }
          driver = {
            type = "qcow2"
          }
        },
      ],
      each.value.type == "worker" ? [
        {
          source = {
            volume = {
              pool   = "default"
              volume = libvirt_volume.ceph_disk[each.key].name
            }
          }
          target = {
            dev = "vdb"
            bus = "virtio"
          }
          driver = {
            type = "raw"
          }
        },
      ] : []
    )

    interfaces = [
      {
        source = {
          bridge = {
            bridge = var.bridge_name
          }
        }
        model = { type = "virtio" }
      },
      {
        source = {
          bridge = {
            bridge = var.bridge_name
          }
        }
        model = { type = "virtio" }
      },
    ]

    consoles = [
      {
        type        = "pty"
        target_port = "0"
        target_type = "serial"
      }
    ]

    graphics = [
      {
        type        = "vnc"
        autoport    = true
        listen_type = "address"
        listen      = "127.0.0.1"
      }
    ]
  }
}

# ---------------------------------------------------------------------------
# Step 6: Apply Talos machine configuration to each node
# ---------------------------------------------------------------------------
# Per-node patches set the hostname, static IP on bond0, gateway, and DNS.
resource "talos_machine_configuration_apply" "node" {
  for_each = local.node_apply

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = each.value.type == "controlplane" ? data.talos_machine_configuration.controlplane.machine_configuration : data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
  apply_mode                  = "auto"

  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = each.key
          interfaces = [
            {
              interface = "bond0"
              addresses = ["${each.value.ip}/${split("/", var.cidr_block)[1]}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = var.gateway
                }
              ]
            }
          ]
        }
      }
      cluster = {
        network = {
          dns = {
            domain      = "${var.cluster_name}.local"
            nameservers = var.dns_servers
          }
        }
      }
    })
  ]

  depends_on = [
    libvirt_domain.node,
  ]

  timeouts = {
    create = "10m"
  }
}

# ---------------------------------------------------------------------------
# Step 7: Bootstrap the first control plane node
# ---------------------------------------------------------------------------
# Waits for all machine configuration applies to succeed before bootstrapping.
resource "talos_machine_bootstrap" "this" {
  node                 = local.cp_ips[0]
  endpoint             = local.cp_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_configuration_apply.node,
  ]

  timeouts = {
    create = "15m"
  }
}

# ---------------------------------------------------------------------------
# Step 8: Retrieve cluster kubeconfig
# ---------------------------------------------------------------------------
resource "talos_cluster_kubeconfig" "this" {
  node                 = local.cp_ips[0]
  endpoint             = local.cp_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_bootstrap.this,
  ]

  timeouts = {
    create = "15m"
  }
}

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
  cluster_name         = var.DEV_CLUSTER_NAME
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
  cluster_name     = var.DEV_CLUSTER_NAME
  machine_type     = "controlplane"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    file("${path.module}/cluster-config.yaml"),
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.DEV_CLUSTER_NAME
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
  capacity = var.DEV_OS_DISK_SIZE_GB * 1073741824

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
  capacity = var.DEV_CEPH_DISK_SIZE_GB * 1073741824

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
  memory      = each.value.type == "controlplane" ? var.DEV_CP_RAM_MB : var.DEV_WORKER_RAM_MB
  memory_unit = "MiB"
  vcpu        = var.DEV_VM_CPU
  running     = true
  autostart   = true

  os = {
    type         = "hvm"
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
            bridge = var.DEV_BRIDGE_NAME
          }
        }
        model = { type = "virtio" }
      },
      {
        source = {
          bridge = {
            bridge = var.DEV_BRIDGE_NAME
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

    # VNC graphics omitted: libvirt provider 0.9.8 has a known bug where
    # the graphics element vanishes on read-back, causing apply failure.
    # VMs are headless (provisioned via serial console / talosctl).
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
          hostname    = each.key
          nameservers = local.dns_servers
          interfaces = [
            {
              interface = "bond0"
              addresses = ["${each.value.ip}/${split("/", var.DEV_CIDR_BLOCK)[1]}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = local.gateway
                }
              ]
            }
          ]
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

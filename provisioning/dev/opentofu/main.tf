# Core provisioning resources for the Talos VM cluster on libvirt/hpa-bridge
#
# Covers the full bootstrap lifecycle:
#   1. Generate machine secrets (TLS + token)
#   2. Create OS disk volumes from pre-built raw images
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
data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.DEV_CLUSTER_NAME
  machine_type     = "controlplane"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.TALOS_VERSION

  config_patches = concat([
    templatefile("${path.module}/cluster-config.yaml.tftpl", {
      gateway           = local.gateway
      cidr_block        = local.cidr_block
      cp_node_names     = join(",", local.cp_node_names)
      worker_node_names = join(",", local.worker_node_names)
    }),
    yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/vdb"
          }
        ]
      }
    })
  ])
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.DEV_CLUSTER_NAME
  machine_type     = "worker"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.TALOS_VERSION

  config_patches = concat([
    templatefile("${path.module}/cluster-config.yaml.tftpl", {
      gateway           = local.gateway
      cidr_block        = local.cidr_block
      cp_node_names     = join(",", local.cp_node_names)
      worker_node_names = join(",", local.worker_node_names)
    }),
    yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/vdb"
          }
        ]
      }
    })
  ])
}

# ---------------------------------------------------------------------------
# Step 2c: Talos ISO — pre-downloaded by startup.sh via wget -c (resumable)
# and placed at /var/lib/libvirt/images/talos-install.iso. Not managed
# by tofu because the libvirt provider's factory download is unreliable.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 2d: OS disk volumes (using pre-built raw images)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 2c: Talos base volume (QCOW2 metal image from local cache or remote factory)
# ---------------------------------------------------------------------------
resource "libvirt_volume" "talos_base" {
  name = "talos-base.qcow2"
  pool = "default"

  create = {
    content = {
      url = var.local_image_path != "" ? "file://${var.local_image_path}" : "${var.DEV_TALOS_IMAGE_FACTORY_URL}/${local.talos_schematic_id}/${var.TALOS_VERSION}/metal-amd64.qcow2"
    }
  }

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# ---------------------------------------------------------------------------
# Step 2d: OS disk volumes (using QCOW2 COW clones)
# ---------------------------------------------------------------------------
resource "libvirt_volume" "os_disk" {
  for_each = toset(local.all_node_names)
  name     = "${each.key}-os.qcow2"
  pool     = "default"
  capacity = var.DEV_OS_DISK_SIZE_GB * 1024 * 1024 * 1024

  backing_store = {
    path = libvirt_volume.talos_base.path
    format = {
      type = "qcow2"
    }
  }

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# ---------------------------------------------------------------------------
# Step 3: Ceph disk volumes (Managed externally on host for persistence)
# ---------------------------------------------------------------------------
# Ceph disks are sparse files created on the host in a dedicated folder.
# They are not managed directly as libvirt_volume resources in tofu so that
# their contents survive "tofu destroy" and "tofu apply" cycles.

# ---------------------------------------------------------------------------
# Step 4: Libvirt domains (VMs)
# ---------------------------------------------------------------------------
# Each VM gets:
#   - Talos ISO overlay on SATA bus (first-boot install to disk)
#   - OS disk on /dev/vda (virtio bus, empty qcow2)
#   - Workers also get a ceph disk on /dev/vdb (virtio bus, raw)
#   - Boot order: cdrom first, hd second (ISO installs Talos to disk on
#     first boot; subsequent boots auto-detect installed Talos via ISO
#     boot menu timer)
#   - One virtio network interface on hpa-bridge (static DHCP lease)
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
    # firmware     = "efi"
    boot_devices = [{ dev = "hd" }]
  }

  cpu = {
    mode = "host-passthrough"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = concat(
      [
        # OS disk: QCOW2 COW clone of the base Talos image.
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
      ])
    yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/vdb"
          }
        ]
      }
    })
  ]),
      each.value.type == "worker" ? [
        # Ceph disk: file-backed sparse raw disk on the host.
        # Stored in /var/lib/libvirt/images/ceph-disks so data survives cluster recreation.
        {
          source = {
            file = {
              file = "/var/lib/libvirt/images/ceph-disks/${each.key}-ceph.img"
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
      ])
    yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/vdb"
          }
        ]
      }
    })
  ]) : []
    )

    interfaces = [
      {
        source = {
          bridge = {
            bridge = var.DEV_BRIDGE_NAME
          }
        }
        model = { type = "virtio" }
        mac = {
          address = local.node_macs[each.key]
        }
      },
    ])
    yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/vdb"
          }
        ]
      }
    })
  ])

    # File-based console logging to capture real-time guest OS logs on the host.
    consoles = [
      {
        type = "file"
        source = {
          path = "/var/log/libvirt/qemu/${each.key}-console.log"
        }
        target = {
          type = "serial"
          port = "0"
        }
      }
    ])
    yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/vdb"
          }
        ]
      }
    })
  ])
  }

}

# ---------------------------------------------------------------------------
# Step 5: Apply Talos machine configuration to each node
# ---------------------------------------------------------------------------
# Per-node patches set the hostname and static IP on eth0.
# Talos boots from the ISO-installed disk into maintenance mode, receives
# config via talosctl (apply_mode auto tries 'try' first for maintenance mode,
# falls back to 'no_reboot' on subsequent runs), and reboots if needed
# with the static IP from the machine config.
resource "talos_machine_configuration_apply" "node" {
  for_each = local.node_apply

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = each.value.type == "controlplane" ? data.talos_machine_configuration.controlplane.machine_configuration : data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
  apply_mode                  = "auto"

  config_patches = concat([
    yamlencode({
      machine = {
        install = {
          disk = "/dev/vda"
        }
        network = {
          nameservers = local.dns_servers
          interfaces = [
            {
              interface = "enp1s0"
              addresses = ["${each.value.ip}/${split("/", var.DEV_CIDR_BLOCK)[1]}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = local.gateway
                }
              ])
    yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/vdb"
          }
        ]
      }
    })
  ])
            }
          ])
    yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/vdb"
          }
        ]
      }
    })
  ])
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
# Step 6: Bootstrap the first control plane node
# ---------------------------------------------------------------------------
resource "talos_machine_bootstrap" "this" {
  node                 = local.cp_ips[0]
  endpoint             = local.cp_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_configuration_apply.node,
  ]

  timeouts = {
    create = "60m"
  }
}

# ---------------------------------------------------------------------------
# Step 7: Retrieve cluster kubeconfig
# ---------------------------------------------------------------------------
resource "talos_cluster_kubeconfig" "this" {
  node                 = local.cp_ips[0]
  endpoint             = local.cp_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_bootstrap.this,
  ]

  timeouts = {
    create = "60m"
  }
}

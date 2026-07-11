# Core provisioning resources for the Talos VM cluster on libvirt/hpa-bridge
#
# Covers the full bootstrap lifecycle:
#   1. Generate machine secrets (TLS + token)
#   2. Create OS disk volumes (COW clones of pre-installed Talos qcow2)
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
# Step 2c: Talos ISO — pre-downloaded by startup.sh via wget -c (resumable)
# and placed at /var/lib/libvirt/images/talos-install.iso. Not managed
# by tofu because the libvirt provider's factory download is unreliable.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 2d: OS disk volumes (empty qcow2 disks, one per node)
# ---------------------------------------------------------------------------
# Each OS disk is an empty qcow2. Talos installs itself to /dev/vda during
# first-boot from the ISO, writing bootloader + rootfs + var partitions.
resource "libvirt_volume" "os_disk" {
  for_each = toset(local.all_node_names)

  name     = "${each.key}-os.qcow2"
  pool     = "default"
  capacity = var.DEV_OS_DISK_SIZE_GB * 1073741824

  target = {
    format = { type = "qcow2" }
  }
}

# ---------------------------------------------------------------------------
# Step 3: Ceph disk volumes (one per worker node, raw, empty)
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
# Step 4: Libvirt domains (VMs)
# ---------------------------------------------------------------------------
# Each VM gets:
#   - Talos ISO overlay on SATA bus (first-boot install to disk)
#   - OS disk on /dev/vda (virtio bus, empty qcow2)
#   - Workers also get a ceph disk on /dev/vdb (virtio bus, raw)
#   - Boot order: hd first, cdrom second (ISO on first boot, Talos installs
#     to disk, subsequent boots use the installed disk)
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
    type             = "hvm"
    type_arch        = "x86_64"
    type_machine     = "q35"
    loader           = "/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2"
    loader_readonly  = "yes"
    loader_type      = "pflash"
    nv_ram = {
      nv_ram   = "/var/lib/libvirt/qemu/nvram/${each.key}_VARS.qcow2"
      template = "/usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2"
    }
    boot_devices = [{ dev = "cdrom" }, { dev = "hd" }]
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
        mac = {
          address = local.node_macs[each.key]
        }
      },
    ]

    consoles = [
      {
        type        = "pty"
        target_port = "0"
        target_type = "serial"
      }
    ]

    # Serial file logging per node — captured at /var/log/libvirt/qemu/<name>-boot.log
    # File-based serial replaces interactive pty; talosctl handles API access.
    serials = [
      {
        type = "file"
        source = {
          path = "/var/log/libvirt/qemu/${each.key}-boot.log"
        }
        target_port = "0"
        target_type = "isa-serial"
      }
    ]

    # VNC graphics omitted: libvirt provider 0.9.8 has a known bug where
    # the graphics element vanishes on read-back, causing apply failure.
    # VMs are headless (provisioned via serial console / talosctl).
  }

}

# ---------------------------------------------------------------------------
# Step 5: Apply Talos machine configuration to each node
# ---------------------------------------------------------------------------
# Per-node patches set the hostname and static IP on eth0.
# Talos boots from the pre-installed disk image, receives config via
# talosctl, and reboots with the static IP from the machine config.
resource "talos_machine_configuration_apply" "node" {
  for_each = local.node_apply

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = each.value.type == "controlplane" ? data.talos_machine_configuration.controlplane.machine_configuration : data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
  apply_mode                  = "no_reboot"

  config_patches = [
    yamlencode({
      machine = {
        network = {
          nameservers = local.dns_servers
          interfaces = [
            {
              interface = "eth0"
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
    create = "20m"
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
    create = "20m"
  }
}

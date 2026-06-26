# Core provisioning resources for the Talos VM cluster on libvirt/hpa-bridge
#
# Covers the full bootstrap lifecycle:
#   1. Generate machine secrets (TLS + token)
#   2. Create OS disk volumes (blank qcow2 for Talos to install onto)
#   3. Create raw empty Ceph disk volumes for worker nodes
#   4. Define libvirt domains (VMs) with OS + ceph disks + ISO
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
# Step 2c: Base Talos ISO download (download once to local disk)
# ---------------------------------------------------------------------------
resource "null_resource" "download_talos_iso" {
  triggers = {
    version = var.TALOS_VERSION
  }

  provisioner "local-exec" {
    command = <<-CMD
      ISO="/var/lib/libvirt/images/talos-v1.13.5.iso"
      if [ ! -f "$ISO" ]; then
        echo "Downloading Talos ISO (320 MB)..."
        curl -Lo "$ISO" "${var.DEV_TALOS_IMAGE_FACTORY_URL}/${local.talos_schematic_id}/${var.TALOS_VERSION}/metal-amd64.iso"
        chmod 644 "$ISO"
        restorecon "$ISO" 2>/dev/null || true
        echo "Download complete."
      else
        echo "Talos ISO already cached."
      fi
CMD
  }
}

# ---------------------------------------------------------------------------
# Step 2d: OS disk volumes (one per node, blank qcow2 for Talos to install onto)
# ---------------------------------------------------------------------------
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
#   - OS disk on /dev/vda (virtio bus, blank qcow2)
#   - Workers also get a ceph disk on /dev/vdb (virtio bus, raw)
#   - One virtio network interface on hpa-bridge (static DHCP lease)
#   - Talos ISO on SATA CDROM (first boot only — Talos live mode)
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
    boot_devices = [{ dev = "cdrom" }, { dev = "hd" }]
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
        # Talos ISO — first boot: live mode enables apply-config to install to vda
        {
          source = {
            file = {
              file = "/var/lib/libvirt/images/talos-v1.13.5.iso"
            }
          }
          target = {
            dev = "sda"
            bus = "sata"
          }
          driver = {
            type = "raw"
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

    # VNC graphics omitted: libvirt provider 0.9.8 has a known bug where
    # the graphics element vanishes on read-back, causing apply failure.
    # VMs are headless (provisioned via serial console / talosctl).
  }

  depends_on = [
    null_resource.download_talos_iso,
  ]
}

# ---------------------------------------------------------------------------
# Step 5: Apply Talos machine configuration to each node
# ---------------------------------------------------------------------------
# Per-node patches set the hostname and static IP on eth0.
# Talos boots from ISO, receives config via talosctl, installs to disk,
# and reboots with the static IP from the machine config.
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
    null_resource.download_talos_iso,
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
    create = "15m"
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
    create = "15m"
  }
}

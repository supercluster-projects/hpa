To attach Ceph block storage (RBD) to your offline Talos Linux VMs using OpenTofu and libvirt, you can configure the libvirt\_volume resource to connect directly to your Ceph cluster pool. This bypasses the need for local host mounts and exposes the Ceph network disk directly to the VM.

## **1\. OpenTofu Ceph Volume Definition**

Define the Ceph pool and volume details directly in your OpenTofu configuration. You must specify the source using the pool/image format and set the provider type to rbd.

`resource "libvirt_volume" "ceph_disk" {`  
  `name     = "talos-ceph-data-disk"`  
  `pool     = "rbd" # Your Ceph pool name`  
  `format   = "raw"`  
  `capacity = 53687091200 # 50 GB in bytes`

  `# Specify Ceph monitors and authentication details`  
  `source = "rbd/talos-ceph-data-disk"`  
`}`

## **2\. Attaching the Ceph Volume to the Talos Domain**

Map the created volume into your libvirt\_domain configuration block. Libvirt will handle the QEMU-to-RBD network mapping natively.

`resource "libvirt_domain" "talos_master" {`  
  `name   = "talos-master-01"`  
  `memory = "4096"`  
  `vcpu   = 2`

  `# Boot disk containing Talos OS`  
  `disk {`  
    `volume_id = libvirt_volume.talos_boot_disk.id`  
  `}`

  `# Direct connection to the Ceph RBD disk`  
  `disk {`  
    `volume_id = libvirt_volume.ceph_disk.id`  
  `}`

  `network_interface {`  
    `network_name = "your-offline-libvirt-network"`  
  `}`  
`}`

## **3\. Libvirt Storage Pool Configuration (Pre-requisite)**

For OpenTofu to manage the RBD volumes, ensure your libvirt daemon has an active storage pool pointed at your Ceph cluster. You can define this pool in OpenTofu as well:

`resource "libvirt_pool" "ceph" {`  
  `name = "rbd"`  
  `type = "rbd"`

  `source {`  
    `name = "rbd" # The Ceph pool name`  
      
    `# List your offline Ceph monitor IPs`  
    `host {`  
      `name = "10.0.0.10"`  
      `port = "6789"`  
    `}`  
    `host {`  
      `name = "10.0.0.11"`  
      `port = "6789"`  
    `}`

    `auth {`  
      `username = "admin"`  
      `secret {`  
        `type = "ceph"`  
        `name = "client.admin secret"`  
      `}`  
    `}`  
  `}`  
`}`

## **4\. Talos Linux Post-Boot Mounts**

Because Talos Linux runs completely in RAM and treats disks immutably, it will discover this Ceph network disk as a standard SCSI device (e.g., /dev/sdb).

To make use of this disk inside Talos (for example, for persistent workloads or etcd storage), you must declare a formatting and mount instruction within your Talos machine configuration file (machineconfig.yaml):

`machine:`  
  `disks:`  
    `- device: /dev/sdb`  
      `partitions:`  
        `- mountpoint: /var/lib/longhorn # Example mount path`

To ensure the Ceph storage integrates correctly with your cluster, please share:

* **How Ceph authentication is handled** (Is it using a ceph.client.admin.keyring or a specific libvirt secret XML uuid?)  
* **What Kubernetes components or storage drivers** (like Rook-Ceph, Talos local path, or Longhorn) will use this disk inside Talos

I can then provide the complete .tf secret management block or the automated partition schemas for your Talos config.
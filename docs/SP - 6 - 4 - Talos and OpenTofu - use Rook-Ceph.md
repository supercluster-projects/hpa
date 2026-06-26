When using **Rook-Ceph** inside Talos Linux, you must pass **raw, unpartitioned, local block devices** directly from the libvirt host into the VMs. Rook-Ceph runs its own Object Storage Daemons (OSDs) inside your Kubernetes cluster and requires full ownership of the raw disks to format them with BlueStore. \[1, 2, 3\]

To achieve this in an offline mode using OpenTofu, you must attach local libvirt storage volumes as secondary raw disks and explicitly configure Talos Linux to grant the Rook containers privileged host access. \[4, 5\]

## **1\. OpenTofu: Attach Raw Secondary Disks**

Every VM serving as a Rook OSD node needs a secondary, completely blank storage volume. Do not format or create filesystems on this volume. \[1, 2, 6\]

`# The primary boot volume for Talos OS`  
`resource "libvirt_volume" "talos_boot" {`  
  `name   = "talos-boot-node1.qcow2"`  
  `pool   = "default"`  
  `source = "/var/lib/libvirt/images/talos-metal.raw" # Your cached offline image`  
  `format = "qcow2"`  
`}`

`# The RAW secondary volume dedicated strictly to Rook-Ceph`  
`resource "libvirt_volume" "ceph_osd_disk" {`  
  `name   = "ceph-osd-node1.raw"`  
  `pool   = "default"`  
  `size   = 107374182400 # 100 GB in bytes`  
  `format = "raw"         # Must be raw for Ceph to probe cleanly`  
`}`

`resource "libvirt_domain" "talos_worker" {`  
  `name   = "talos-worker-01"`  
  `memory = "8192" # Ceph OSDs are memory intensive; assign at least 4-8GB`  
  `vcpu   = 4`

  `# Boot Disk`  
  `disk {`  
    `volume_id = libvirt_volume.talos_boot.id`  
  `}`

  `# Rook-Ceph OSD Disk (Will appear as /dev/vdb or /dev/sdb inside the VM)`  
  `disk {`  
    `volume_id = libvirt_volume.ceph_osd_disk.id`  
  `}`

  `network_interface {`  
    `network_name = "your-offline-network"`  
  `}`  
`}`

## **2\. Talos Machine Configuration Changes**

Because Talos Linux is an immutable, hardened operating system, you must configure two crucial components in your worker node machineconfig.yaml to allow Rook-Ceph to manage the raw hardware: \[4, 5, 7\]

1. **Load the RBD kernel module** natively.  
2. **Expose mount paths and elevate privileges** so the Kubernetes Kubelet allows Rook to claim /dev/ devices. \[5, 8, 9\]

`machine:`  
  `kernel:`  
    `modules:`  
      `- name: rbd # Required for Ceph block device mapping`  
  `kubelet:`  
    `extraMounts:`  
      `- source: /var/lib/rook`  
        `destination: /var/lib/rook`  
        `type: bind`  
        `options:`  
          `- bind`  
          `- rshared`  
      `- source: /dev`  
        `destination: /dev`  
        `type: bind`  
        `options:`  
          `- bind`  
          `- rshared`  
*`# NOTE: Do NOT list your secondary disk (/dev/vdb) under machine.disks.`*   
*`# Leaving it out ensures Talos ignores it, keeping it blank for Rook.`*

## **3\. Deploying Rook-Ceph Offline via Helm**

Since you are in an offline network, you cannot pull the standard Rook Helm charts directly from the internet. \[10\]

1. **On a connected machine**, pull the Helm chart and save it as an archive:  
   `helm repo add rook-release https://charts.rook.io/release`  
   `helm repo update`  
   `helm pull rook-release/rook-ceph --version <version>`

2. **Transfer the .tgz file** to your offline system.  
3. **Configure your custom values.yaml** to account for the Talos specific Kubelet directory and point to your local offline registry cache:  
   *`# rook-values.yaml`*  
   `image:`  
     `repository: your-local-registry.internal/rook/ceph # Point to local cache`

   `kubeletDirPath: /var/lib/kubelet # Critical for Talos Linux pathing`

   `csi:`  
     `enableRbdDriver: true`  
     `enableCephfsDriver: true`  
     `kubeletDirPath: /var/lib/kubelet`

4. **Install the operator** utilizing the local tarball:  
   `helm install rook-ceph ./rook-ceph-<version>.tgz \`  
     `--namespace rook-ceph \`  
     `--create-namespace \`  
     `-f rook-values.yaml`  
   \[10, 11, 12\]

## **4\. Rook-Ceph Cluster Configuration**

When you apply your CephCluster Custom Resource, instruct Rook to scan for all unformatted local disks explicitly. It will discover your secondary libvirt raw disk (/dev/vdb) automatically: \[1\]

`apiVersion: ceph.rook.io/v1`  
`kind: CephCluster`  
`metadata:`  
  `name: rook-ceph`  
  `namespace: rook-ceph`  
`spec:`  
  `cephVersion:`  
    `image: your-local-registry.internal/ceph/ceph:v18.2.0 # Offline registry image`  
  `dataDirHostPath: /var/lib/rook`  
  `storage:`  
    `useAllNodes: true`  
    `useAllDevices: true # Rook will find and use the blank libvirt disk safely`

To verify this configuration will operate smoothly, please let me know:

* **How many worker nodes** you are spinning up with OpenTofu (Rook ideally requires a minimum of **3 nodes** for default data replication).  
* Whether you are using a **local private container registry** (like Harbor) or aiming to inject the Rook container images using **Talos image caching tools**?

I can tailor the OpenTofu code loop for multiple VMs or outline the exact manual image sideloading commands.

\[1\] [https://www.youtube.com](https://www.youtube.com/watch?v=98QujsS7jFI)  
\[2\] [https://rook.io](https://rook.io/docs/rook/latest/Getting-Started/Prerequisites/prerequisites/)  
\[3\] [https://www.youtube.com](https://www.youtube.com/watch?v=pIms7oW7Ebo)  
\[4\] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-03-set-up-rook-ceph-storage-cluster-on-talos-linux/view)  
\[5\] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-03-set-up-ceph-storage-on-talos-linux/view)  
\[6\] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-03-set-up-ceph-storage-on-talos-linux/view)  
\[7\] [https://www.fairbanks.nl](https://www.fairbanks.nl/building-a-sovereign-kubernetes-cluster-with-talos-linux-and-ceph-storage/)  
\[8\] [https://docs.starlingx.io](https://docs.starlingx.io/r/stx.6.0/operations/storage_migration_from_ceph_to_rook.html)  
\[9\] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-31-rook-deploy-rook-ceph-red-hat-openshift-detailed/view)  
\[10\] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-03-configure-rook-ceph-on-talos-linux/view)  
\[11\] [https://oracle.github.io](https://oracle.github.io/weblogic-kubernetes-operator/managing-operators/preparation/)  
\[12\] [https://github.com](https://github.com/canonical/microk8s/issues/4314)
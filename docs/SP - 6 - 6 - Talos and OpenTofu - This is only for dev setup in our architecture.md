To bring this specific architecture to life for your local **Dev** setup, you need the OpenTofu code to spin up the local libvirt VMs, configure the Talos bootstrap options (without kube-proxy), attach the raw disks for Rook-Ceph, and hook into your GitOps layout.

Since this is a Dev setup, we will configure a single-node or lightweight 3-node OpenTofu configuration using local files and variables.

## **1\. OpenTofu Variables & Providers (environments/dev/main.tf)**

This configuration pulls Talos and Libvirt providers together while assuming your local mirror caches are ready.

`terraform {`  
  `required_version = ">= 1.6.0"`  
  `required_providers {`  
    `libvirt = {`  
      `source  = "dmacvicar/libvirt"`  
      `version = "0.8.3"`  
    `}`  
    `talos = {`  
      `source  = "siderolabs/talos"`  
      `version = "0.7.0"`  
    `}`  
  `}`  
`}`

`provider "libvirt" {`  
  `uri = "qemu:///system"`  
`}`

`variable "cluster_name" {`  
  `type    = string`  
  `default = "talos-dev"`  
`}`

`# Offline Local Paths`  
`variable "talos_iso_path" {`  
  `type    = string`  
  `default = "/var/lib/libvirt/images/talos-amd64-cached.iso"`  
`}`

## **2\. Network & Storage Pools**

We establish an isolated host-only/NAT network for your offline dev cluster and set up the raw disk generation for Rook-Ceph.

`resource "libvirt_network" "dev_net" {`  
  `name      = "talos-dev-net"`  
  `mode      = "nat"`  
  `domain    = "dev.local"`  
  `addresses = ["10.10.10.0/24"]`  
  `dhcp {`  
    `enabled = true`  
  `}`  
`}`

`# Standard OS Volumes`  
`resource "libvirt_volume" "os_disk" {`  
  `count  = 3`  
  `name   = "talos-dev-os-${count.index}.qcow2"`  
  `pool   = "default"`  
  `size   = 21474836480 # 20 GB`  
  `format = "qcow2"`  
`}`

`# RAW Unformatted volumes dedicated strictly for Rook-Ceph`  
`resource "libvirt_volume" "rook_ceph_disk" {`  
  `count  = 3`  
  `name   = "talos-dev-ceph-${count.index}.raw"`  
  `pool   = "default"`  
  `size   = 53687091200 # 50 GB`  
  `format = "raw"`  
`}`

## **3\. Generate Talos Machine Configurations**

Using the talos provider, generate the configurations while explicitly **disabling kube-proxy** and passing the Kubelet directory alterations required for Rook-Ceph and Cilium. \[1\]

`resource "talos_machine_secrets" "this" {}`

`data "talos_machine_configuration" "controlplane" {`  
  `cluster_name     = var.cluster_name`  
  `cluster_endpoint = "https://10.10.10" # Explicit static mapping for dev`  
  `machine_type     = "controlplane"`  
  `machine_secrets  = talos_machine_secrets.this.machine_secrets`  
    
  `config_patches = [`  
    `yamlencode({`  
      `machine = {`  
        `kernel = {`  
          `modules = [{ name = "rbd" }]`  
        `}`  
        `kubelet = {`  
          `extraMounts = [`  
            `{ source = "/var/lib/rook", destination = "/var/lib/rook", type = "bind", options = ["bind", "rshared"] },`  
            `{ source = "/dev", destination = "/dev", type = "bind", options = ["bind", "rshared"] }`  
          `]`  
        `}`  
      `},`  
      `cluster = {`  
        `network = {`  
          `cni = { name = "none" } # Handled by your infrastructure/cilium app`  
        `}`  
        `proxy = {`  
          `disabled = true # Kube-proxy-free mode`  
        `}`  
      `}`  
    `})`  
  `]`  
`}`

## **4\. Create the Domain VMs**

Bind the raw secondary disks and machine configurations directly to the libvirt domain assets.

`resource "libvirt_domain" "nodes" {`  
  `count  = 3`  
  `name   = "talos-dev-node-${count.index}"`  
  `memory = "6144" # Ceph OSDs + your telemetry engine stack require decent dev memory`  
  `vcpu   = 2`

  `# Pass Talos ISO directly`  
  `disk {`  
    `file = var.talos_iso_path`  
  `}`

  `# Primary OS disk`  
  `disk {`  
    `volume_id = libvirt_volume.os_disk[count.index].id`  
  `}`

  `# Raw secondary disk passed untouched to Rook-Ceph`   
  `disk {`  
    `volume_id = libvirt_volume.rook_ceph_disk[count.index].id`  
  `}`

  `network_interface {`  
    `network_id     = libvirt_network.dev_net.id`  
    `wait_for_lease = true`  
  `}`

  `# Inject configuration meta via native qemu guest commands if using cloud-init`   
  ``# or use standard `talos_machine_configuration_apply` post deployment.``  
`}`

## **5\. Hooking to your GitOps Repository Structure**

Once OpenTofu finishes provisioning these 3 nodes, you can run the bootstrap step. Your bootstrap/root-application.yaml will point directly to the infrastructure/ paths.

To bridge the gap between OpenTofu and your GitOps architecture, here is the structure you can place inside infrastructure/cilium/values.yaml to match this Dev loop:

*`# infrastructure/cilium/values.yaml`*  
`kubeProxyReplacement: true`  
`k8sServiceHost: 10.10.10.10 # Matches the cluster endpoint defined in OpenTofu`  
`k8sServicePort: 7445       # Talos native load-balancer fallback port`  
`cni:`  
  `binPath: /var/libexec/cni`  
  `confPath: /etc/cni/net.d`  
`cgroupsPath: /run/current-system/cgroup`  
`image:`  
  `repository: your-local-registry.internal/cilium/cilium`  
  `tag: v1.17.0`  
  `useDigest: false`

And your Rook-Ceph config matches the blank raw storage nodes:

*`# infrastructure/rook-ceph/cluster-values.yaml`*  
`storage:`  
  `useAllNodes: true`  
  `useAllDevices: true # Will automatically claim /dev/vdb or /dev/sdb provided by OpenTofu`

To continue assembling your **Dev** environment files, would you like to:

* Generate the full **ArgoCD root-application.yaml manifest** that recursively targets your platform configurations?  
* Flesh out the exact **VictoriaMetrics config variants** inside observability/metrics/ to match your low-resource dev environment?

\[1\] [https://github.com](https://github.com/achetronic/homelab-ops)
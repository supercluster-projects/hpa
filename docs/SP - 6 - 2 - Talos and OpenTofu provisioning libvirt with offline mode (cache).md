Provisioning [Talos Linux](https://www.talos.dev/) on [libvirt](https://search.opentofu.org/provider/dmacvicar/libvirt/v0.8.3) using [OpenTofu](https://opentofu.org/) in offline mode requires two separate cache layers: local provider binaries for OpenTofu, and a built-in container/image cache for Talos nodes to prevent upstream internet access. \[1, 2, 3\]

## **1\. Offline Provider Cache for OpenTofu**

To run OpenTofu completely offline, you must download provider plugins on an internet-connected machine and mirror them locally.

1. Create a .tofurc or \~/.tofurc configuration file to define your local plugin cache: \[1, 3, 4\]

plugin\_cache\_dir \= "$HOME/.opentofu/plugin-cache"

1. On your connected machine, use the [OpenTofu Plugin Mirror Command](https://opentofu.org/docs/cli/plugins/) to download the required plugins (such as the dmacvicar/libvirt provider) into a local directory: \[1, 5\]

tofu providers mirror /path/to/local/mirror/dir

1. Transfer /path/to/local/mirror/dir to your offline libvirt host.  
2. Configure OpenTofu on the offline system to utilize the local mirror by adding a provider\_installation block in your .tofurc or in versions.tf: \[1, 3\]

provider\_installation {  
  filesystem\_mirror {  
    path     \= "/path/to/local/mirror/dir"  
    include  \= \["registry.opentofu.org/\*/\*"\]  
  }  
}

## **2\. Talos Linux Offline Mode & Image Caching**

Talos Linux requires all Kubernetes components (like the kube-apiserver and kube-proxy) and image assets to be pre-loaded, as it does not include standard package managers or an internet connection to pull from upstream registries. \[6\]

## **Option A: Custom Image with Built-in Cache**

1. Use [talosctl](https://www.talos.dev/v1.9/introduction/getting-started/) on an internet-connected machine to create a custom ISO with a built-in image cache:

talosctl image cache \--with-kubernetes \--image-registry k8s.gcr.io ...

1. Define your libvirt\_domain in OpenTofu to use this custom, cached ISO as the CDROM source: \[5\]

resource "libvirt\_volume" "talos\_iso" {  
  name   \= "talos-offline.iso"  
  source \= "/local/path/to/your/cached-talos.iso"  
}

## **Option B: Image Mount Sequence**

Talos supports mounting secondary ISOs or disks to dynamically copy images into its internal cache. \[6\]

1. Create a secondary ISO containing the required Talos assets using talosctl.  
2. Map the ISO as a disk volume in your OpenTofu libvirt\_domain definition.  
3. Once the VM boots, Talos automatically copies the images from the mounted ISO to its internal cache. \[6\]

## **3\. Libvirt Volume & Network Configuration**

When spinning up Talos nodes, configure your OpenTofu libvirt domain with strict network isolation to guarantee the offline node never attempts external outbound calls. \[5\]

resource "libvirt\_domain" "talos\_master" {  
  name   \= "talos-master-01"  
  memory \= "4096"  
  vcpu   \= 2

  disk {  
    volume\_id \= libvirt\_volume.talos\_boot\_disk.id  
  }

  \# Secondary ISO volume used to populate Talos image cache  
  disk {  
    volume\_id \= libvirt\_volume.talos\_cache\_iso.id  
  }

  network\_interface {  
    network\_name   \= "your-offline-libvirt-network"  
    wait\_for\_lease \= true  
  }  
}

Could you tell me:

* **How your offline OpenTofu mirror and plugins are currently organized**  
* **The specific Kubernetes version and Talos configuration version** you intend to run

I can provide the exact talosctl commands and OpenTofu registry overrides you need to complete the local setup.

\[1\] [https://opentofu.org](https://opentofu.org/docs/cli/plugins/)  
\[2\] [https://docs.siderolabs.com](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/virtualized-platforms/vagrant-libvirt)  
\[3\] [https://opentofu.org](https://opentofu.org/docs/language/providers/)  
\[4\] [https://opentofu.org](https://opentofu.org/docs/cli/config/config-file/)  
\[5\] [https://search.opentofu.org](https://search.opentofu.org/provider/dmacvicar/libvirt/v0.8.3)  
\[6\] [https://github.com](https://github.com/siderolabs/talos/discussions/12944)
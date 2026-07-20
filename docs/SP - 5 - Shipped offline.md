To ship this entire architecture to a completely **offline, air-gapped bare-metal environment**, you must build an integrated **"Seeding Appliance"** (typically a rugged USB drive, a local NAS, or a single bootstrap laptop) that carries every dependency pre-packaged.

Because you have no access to the internet, you must bundle the **OpenTofu provider binaries, raw OS cloud-init QCOW2 images, Helm charts, and OCI container/Wasm layers** ahead of time.

Here is the strategic plan to package, transport, and unpack your stack offline.

## ---

**Phase 1: The Offline Packaging Layout (On the Internet Side)**

On a machine with internet access, you create a structured staging directory on your transport media (e.g., an external SSD). You run a series of fetch operations to extract everything required by your GitOps pipeline:

/media/seed-appliance/  
├── 1-operating-systems/  
│   ├── ubuntu-24.04-server-cloudimg-amd64.img \# Base QCOW2 image for QEMU  
│   └── matchbox-os-images/                   \# PXE boot files for Prod hardware  
├── 2-tofu-registry/  
│   └── registry.opentofu.org/  
│       └── dmacvicar/libvirt/                \# Offline libvirt provider binary  
├── 3-helm-charts/                            \# Packaged .tgz chart archives  
│   ├── cilium-1.16.0.tgz  
│   ├── argo-cd-7.3.0.tgz  
│   └── kargo-0.4.0.tgz  
└── 4-oci-registry-dump/                      \# Raw image tars for your Harbor seed  
    ├── casdoor.tar  
    ├── spinkube-operator.tar  
    ├── knative-serving.tar  
    └── victoriametrics-cluster.tar

## **The Fetching Commands**

To gather these files, you execute these steps on your internet-connected workstation:

*\# 1\. Download Helm Charts offline*  
helm repo add argo https://github.io  
helm dependency build ./charts/argocd \--destination /media/seed-appliance/3-helm-charts/

*\# 2\. Pull and save all OCI container & Wasm runtime images as tarballs*  
docker pull casdoor/casdoor:v1.500.0  
docker save casdoor/casdoor:v1.500.0 \-o /media/seed-appliance/4-oci-registry-dump/casdoor.tar

*\# 3\. Cache OpenTofu providers for local filesystem mirrors*  
export TOFU\_DATA\_DIR="/media/seed-appliance/2-tofu-registry"  
tofu providers mirror /media/seed-appliance/2-tofu-registry

## ---

**Phase 2: The Infrastructure Provisioning Layer (The Bootstrap Machine)**

When you walk into the air-gapped facility, plug your transport media into the primary machine that can talk to the server hardware or local libvirt networks.

## **1\. Direct OpenTofu to use the Local Filesystem Mirror**

To make OpenTofu work cleanly in Dev or Staging without hitting the internet public registry, configure an explicit provider installation policy via an .tofurc or tofu.tfrc file on the bootstrap runner machine:

\# \~/.tofurc config file on the offline runner machine  
provider\_installation {  
  filesystem\_mirror {  
    path    \= "/media/seed-appliance/2-tofu-registry"  
    include \= \["registry.opentofu.org/\*/\*"\]  
  }  
  direct {  
    exclude \= \["\*"\]  
  }  
}

*When you execute tofu init inside your provisioning/tofu-libvirt-dev/ directory, OpenTofu pulls the libvirt plugin straight from your SSD, avoiding any network timeouts.*

## ---

**Phase 3: In-Cluster Air-Gapped Bootstrap (The Seed Loop)**

Once OpenTofu brings up your target development or staging virtual machine nodes, you must execute a specific **three-step bootstrap sequence** to pass the data payloads directly into the cluster.

\[ Transport Media \]  
        │  
        ├── (1. Load OS Images) ────► \[ Local Node Host QEMU/libvirt Storage Pool \]  
        │  
        ├── (2. Load Core Tars) ────► \[ Air-Gapped Container Registry (Harbor) \]  
        │  
        └── (3. Deploy Manifests) ──► \[ ArgoCD / Kargo Control Loops \]

## **Step 1: Populate Local Node Storage Pools**

Your OpenTofu scripts reference your local settings file (cluster-config.yaml). Ensure the image path targets the directory where you copied the base operating system cloud image:

cluster:  
  base\_image: "/media/seed-appliance/1-operating-systems/ubuntu-24.04-server-cloudimg-amd64.img"

## **Step 2: Seed Your Internal Registry (Harbor Instance)**

Every container image and Wasm module must live inside your local private **Harbor** registry. You script the ingestion loop on the bootstrap host:

*\# Push container structures straight into your local offline registry network*  
docker load \-i /media/seed-appliance/4-oci-registry-dump/casdoor.tar  
docker tag casdoor/casdoor:v1.500.0 harbor.private.lan/iam/casdoor:v1.500.0  
docker push harbor.private.lan/iam/casdoor:v1.500.0

## **Step 3: Hydrate ArgoCD Helm Repositories Natively**

Because ArgoCD can no longer pull charts directly from public Git or Helm endpoints, your gitops-infra repository configures ArgoCD to use internal file locations or pointers to your local Harbor registry (since modern Harbor handles Helm charts as OCI artifacts):

apiVersion: v1  
kind: ConfigMap  
metadata:  
  name: argocd-cm  
  namespace: argocd  
data:  
  *\# Instructs ArgoCD to fetch charts natively from your air-gapped harbor server*  
  helm.repositories: |  
    \- url: https://private.lan  
      name: offline-platform-repo

## ---

**Phase 4: Activating Spegel as Your Network Shield**

Once your air-gapped registry is filled and ArgoCD begins applying configurations, **Spegel** acts as your primary network shield.

In an offline environment, your localized network lines are valuable assets. When your high-throughput **SpinKube** data processors trigger a massive scale-up to handle a 50,000+ RPS burst on Kafka telemetry data:

1. Node 1 requests the updated analytics processing .wasm layer from Harbor.  
2. Nodes 2 through 20 completely bypass Harbor. They pull the layers directly from Node 1 via **Spegel’s peer-to-peer distribution** on your local bare-metal network switches.

This pattern isolates your central Harbor seed machine from high network strain, preventing it from becoming a bottleneck during scaling events.

## ---

**The Complete Shipping Checklist**

| Component Stage | Online Extraction Task (Workstation) | Offline Hydration Task (Air-Gapped Targets) |
| :---- | :---- | :---- |
| **OpenTofu Plugins** | Run tofu providers mirror to capture binaries. | Drop local registry files and link them via a .tofurc config file. |
| **Cluster Images** | Pull base cloud QCOW2 paths and Matchbox PXE states. | Copy directly into libvirt's storage pools or local network boot paths. |
| **Applications Core** | Export every container/Wasm module tag to .tar files. | Run docker load and push them directly to your internal Harbor registry. |
| **GitOps State** | Pull raw Helm packages as .tgz files into your repo. | Commit packaged paths directly into your local offline Git repository server. |

We have now mapped out your entire architecture, repository directories, storage optimizations, observability backends, and offline deployment strategies.

Would you like to start by generating the **OpenTofu configuration files** to initialize your local virtual machines, or would you prefer to build the **Casbin PERM policy file** to define your core access control rules?